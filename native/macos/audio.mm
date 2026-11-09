#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <libproc.h>
#include "mvm_audio.h"
#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <map>
#include <chrono>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <unistd.h>

namespace {
struct Failure : std::runtime_error {
    std::string code;
    OSStatus status;
    Failure(const char *c, const char *message, OSStatus s = 0) : std::runtime_error(message), code(c), status(s) {}
};
void check(OSStatus s, const char *operation) {
    if (s != noErr) throw Failure("BackendFailure", operation, s);
}
AudioObjectPropertyAddress address(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal, UInt32 element = kAudioObjectPropertyElementMain) {
    return {selector, scope, element};
}
template<typename T> T read(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal, UInt32 element = 0) {
    T value{}; UInt32 size = sizeof(T); auto a = address(selector, scope, element);
    check(AudioObjectGetPropertyData(object, &a, 0, nullptr, &size, &value), "Read audio property failed");
    return value;
}
template<typename T> void write(AudioObjectID object, AudioObjectPropertySelector selector, T value, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal, UInt32 element = 0) {
    auto a = address(selector, scope, element);
    check(AudioObjectSetPropertyData(object, &a, 0, nullptr, sizeof(T), &value), "Write audio property failed");
}
std::vector<AudioObjectID> objects(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
    auto a = address(selector, scope); UInt32 size = 0;
    check(AudioObjectGetPropertyDataSize(object, &a, 0, nullptr, &size), "Enumerate audio objects failed");
    std::vector<AudioObjectID> result(size / sizeof(AudioObjectID));
    if (size) check(AudioObjectGetPropertyData(object, &a, 0, nullptr, &size, result.data()), "Enumerate audio objects failed");
    result.resize(size / sizeof(AudioObjectID)); return result;
}
NSString *stringProperty(AudioObjectID object, AudioObjectPropertySelector selector) {
    CFStringRef value = nullptr;
    try { value = read<CFStringRef>(object, selector); } catch (...) { return @""; }
    return value ? CFBridgingRelease(value) : @"";
}
bool settable(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope, UInt32 element) {
    auto a = address(selector, scope, element); Boolean value = false;
    return AudioObjectHasProperty(object, &a) && AudioObjectIsPropertySettable(object, &a, &value) == noErr && value;
}
UInt32 channels(AudioObjectID device, AudioObjectPropertyScope scope) {
    auto a = address(kAudioDevicePropertyStreamConfiguration, scope); UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, nullptr, &size) || size < sizeof(AudioBufferList)) return 0;
    std::vector<unsigned char> bytes(size); auto *list = reinterpret_cast<AudioBufferList *>(bytes.data());
    if (AudioObjectGetPropertyData(device, &a, 0, nullptr, &size, list)) return 0;
    UInt32 count = 0; for (UInt32 i = 0; i < list->mNumberBuffers; ++i) count += list->mBuffers[i].mNumberChannels;
    return count;
}
AudioObjectID defaultDevice(bool input) {
    try { return read<AudioObjectID>(kAudioObjectSystemObject, input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice); }
    catch (...) { return kAudioObjectUnknown; }
}
AudioObjectID defaultOutput() { return defaultDevice(false); }
AudioObjectID resolveDevice(NSString *uid) {
    for (auto d : objects(kAudioObjectSystemObject, kAudioHardwarePropertyDevices)) if ([stringProperty(d, kAudioDevicePropertyDeviceUID) isEqualToString:uid]) return d;
    throw Failure("DeviceUnavailable", "Audio device is no longer available");
}
std::vector<UInt32> controls(AudioObjectID d, AudioObjectPropertySelector property, AudioObjectPropertyScope scope) {
    if (settable(d, property, scope, 0)) return {0};
    std::vector<UInt32> result;
    for (UInt32 c = 1; c <= channels(d, scope); ++c) if (settable(d, property, scope, c)) result.push_back(c);
    return result;
}
struct App {
    NSString *key; NSString *name;
    NSString *unsupportedReason = nil;
    std::vector<AudioObjectID> processes;
    bool compatible = true;
};
NSString *identity(pid_t pid, NSString **name) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    char path[PROC_PIDPATHINFO_MAXSIZE] = {};
    if (proc_pidpath(pid, path, sizeof(path)) > 0) {
        NSString *executable = [NSString stringWithUTF8String:path];
        // Resolve nested helpers to their outer application bundle.
        NSRange range = [executable rangeOfString:@".app/"];
        if (range.location != NSNotFound) {
            NSString *bundlePath = [executable substringToIndex:range.location + 4];
            NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
            *name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: bundlePath.lastPathComponent;
            if (bundle.bundleIdentifier) return bundle.bundleIdentifier;
        }
        if (app.bundleIdentifier && app.localizedName) { *name = app.localizedName; return app.bundleIdentifier; }
        *name = executable.lastPathComponent; return [@"path:" stringByAppendingString:executable];
    }
    *name = [NSString stringWithFormat:@"进程 %d", pid];
    return [NSString stringWithFormat:@"pid:%d", pid];
}
std::map<std::string, App> enumerateApps() {
    std::map<std::string, App> result;
    AudioObjectID output = defaultOutput();
    if (!output) return result;
    for (auto object : objects(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList)) {
        try {
            pid_t pid = read<pid_t>(object, kAudioProcessPropertyPID);
            if (pid == getpid() || !read<UInt32>(object, kAudioProcessPropertyIsRunningOutput)) continue;
            NSString *name = nil; NSString *key = identity(pid, &name);
            if ([key hasPrefix:@"com.macvoicemix."] || [key containsString:@"mac-voice-mix"]) continue;
            auto &a = result[key.UTF8String]; a.key = key; a.name = name; a.processes.push_back(object);
            if ([key containsString:@"com.apple.WebKit"]) { a.compatible = false; a.unsupportedReason = @"暂时无法确定此 WebKit 音频进程所属的应用。"; }
            auto used = objects(object, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput);
            if (used.size() != 1 || used[0] != output) { a.compatible = false; a.unsupportedReason = @"此应用未仅使用系统默认输出设备。"; }
        } catch (...) { /* A process may disappear while enumerating. Skip this stale object. */ }
    }
    return result;
}
// AudioBufferList access works for both interleaved and planar float32.
const float *samplePointer(const AudioBufferList *list, UInt32 channel, UInt32 frame) {
    if (!list) return nullptr;
    for (UInt32 b = 0; b < list->mNumberBuffers; ++b) {
        const auto &buffer = list->mBuffers[b];
        if (channel < buffer.mNumberChannels) {
            size_t index = size_t(frame) * buffer.mNumberChannels + channel;
            return buffer.mData && (index + 1) * sizeof(float) <= buffer.mDataByteSize ? static_cast<const float *>(buffer.mData) + index : nullptr;
        }
        channel -= buffer.mNumberChannels;
    }
    return nullptr;
}
struct Session {
    AudioObjectID tap = 0, aggregate = 0;
    AudioDeviceIOProcID io = nullptr;
    std::atomic<float> target{1};
    std::atomic<uint64_t> callbacks{0}, invalidBuffers{0};
    std::atomic<float> inputRms{0}, outputRms{0}, appliedGain{1};
    static_assert(std::atomic<float>::is_always_lock_free, "Realtime float atomics must be lock free");
    static_assert(std::atomic<uint64_t>::is_always_lock_free, "Realtime counters must be lock free");
    double sampleRate = 0;
    std::chrono::steady_clock::time_point lastProgress = std::chrono::steady_clock::now();
    uint64_t observedCallbacks = 0;
    float gain = 1; UInt32 physicalInputs = 0; float step = 0.002f;
    std::vector<AudioObjectID> processes;
    NSString *outputUID;
    bool started = false;
    OSStatus stop() {
        // MutedWhenTapped restores original output when IO stops.
        if (started) {
            OSStatus status = AudioDeviceStop(aggregate, io);
            if (status) return status; // Keep callback storage alive if stopping failed.
            started = false;
        }
        if (io) { OSStatus s = AudioDeviceDestroyIOProcID(aggregate, io); if (s) return s; io = nullptr; }
        if (aggregate) { OSStatus s = AudioHardwareDestroyAggregateDevice(aggregate); if (s) return s; aggregate = 0; }
        if (tap) { OSStatus s = AudioHardwareDestroyProcessTap(tap); if (s) return s; tap = 0; }
        return noErr;
    }
};
OSStatus render(AudioObjectID, const AudioTimeStamp *, const AudioBufferList *input, const AudioTimeStamp *, AudioBufferList *output, const AudioTimeStamp *, void *data) {
    auto *s = static_cast<Session *>(data); s->callbacks.fetch_add(1, std::memory_order_relaxed);
    if (!output) return noErr;
    UInt32 frames = 0;
    for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
        auto &buffer = output->mBuffers[b];
        if (buffer.mData) memset(buffer.mData, 0, buffer.mDataByteSize);
        if (buffer.mNumberChannels) frames = std::max(frames, buffer.mDataByteSize / (UInt32(sizeof(float)) * buffer.mNumberChannels));
    }
    const float target = s->target.load(std::memory_order_relaxed);
    double inputEnergy = 0, outputEnergy = 0; uint64_t samples = 0;
    for (UInt32 frame = 0; frame < frames; ++frame) {
        float delta = target - s->gain;
        s->gain += std::clamp(delta, -s->step, s->step);
        for (UInt32 channel = 0; channel < 2; ++channel) {
            const float *source = samplePointer(input, s->physicalInputs + channel, frame);
            float *dest = const_cast<float *>(samplePointer(output, channel, frame));
            if (source && dest) {
                *dest = *source * s->gain;
                inputEnergy += double(*source) * *source;
                outputEnergy += double(*dest) * *dest;
                ++samples;
            }
            else s->invalidBuffers.fetch_add(1, std::memory_order_relaxed);
        }
    }
    s->inputRms.store(samples ? float(std::sqrt(inputEnergy / samples)) : 0, std::memory_order_relaxed);
    s->outputRms.store(samples ? float(std::sqrt(outputEnergy / samples)) : 0, std::memory_order_relaxed);
    s->appliedGain.store(s->gain, std::memory_order_relaxed);
    return noErr;
}
void validateStreams(AudioObjectID device, AudioObjectPropertyScope scope) {
    for (auto stream : objects(device, kAudioDevicePropertyStreams, scope)) {
        auto format = read<AudioStreamBasicDescription>(stream, kAudioStreamPropertyVirtualFormat);
        if (format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat) || format.mBitsPerChannel != 32 || !(format.mFormatFlags & kAudioFormatFlagIsPacked))
            throw Failure("Unsupported", "This device does not expose supported float32 PCM streams");
    }
}
struct Context {
    std::map<std::string, std::unique_ptr<Session>> sessions;
    NSMutableDictionary *errors = [NSMutableDictionary dictionary];
    NSString *permission = @"unknown";
    uint64_t revision = 0;
    OSStatus remove(const std::string &key) {
        auto it = sessions.find(key); if (it == sessions.end()) return noErr;
        OSStatus s = it->second->stop(); if (!s) sessions.erase(it); return s;
    }
    void shutdown() {
        for (auto it = sessions.begin(); it != sessions.end();) {
            check(it->second->stop(), "Unable to restore audio; retry stopping the mixer");
            it = sessions.erase(it);
        }
    }
};
void createSession(Context &context, const App &app, float gain) {
    AudioObjectID output = defaultOutput();
    if (!app.compatible || channels(output, kAudioObjectPropertyScopeOutput) != 2)
        throw Failure("Unsupported", "First version supports stereo apps routed to the default output only");
    validateStreams(output, kAudioObjectPropertyScopeOutput);
    auto session = std::make_unique<Session>();
    session->processes = app.processes; session->target.store(gain); session->gain = 1;
    session->physicalInputs = 0; // Only output channels are included; never open microphone streams.
    session->outputUID = stringProperty(output, kAudioDevicePropertyDeviceUID);
    auto rate = read<Float64>(output, kAudioDevicePropertyNominalSampleRate);
    if (!std::isfinite(rate) || rate <= 0) throw Failure("Unsupported", "Invalid output sample rate");
    session->sampleRate = rate;
    session->step = float(1.0 / std::max(1.0, rate * 0.01));
    Session *s = session.get();
    // Store before creating resources; all partial construction is owned and cleaned up.
    if (!context.sessions.emplace(app.key.UTF8String, std::move(session)).second) throw Failure("Busy", "Application already has a mixer session");
    try {
        NSMutableArray *processes = [NSMutableArray array]; for (auto p : app.processes) [processes addObject:@(p)];
        CATapDescription *description = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
        description.privateTap = YES; description.muteBehavior = CATapMutedWhenTapped;
        description.name = @"Mac Voice Mix application tap";
        check(AudioHardwareCreateProcessTap(description, &s->tap), "Create process tap failed (check System Audio Recording permission)");
        auto format = read<AudioStreamBasicDescription>(s->tap, kAudioTapPropertyFormat);
        if (format.mFormatID != kAudioFormatLinearPCM || !(format.mFormatFlags & kAudioFormatFlagIsFloat) || format.mBitsPerChannel != 32 || format.mChannelsPerFrame != 2)
            throw Failure("Unsupported", "Unsupported process tap format");
        NSString *tapUID = stringProperty(s->tap, kAudioTapPropertyUID);
        NSDictionary *composition = @{
            @kAudioAggregateDeviceNameKey: @"Mac Voice Mix private output",
            @kAudioAggregateDeviceUIDKey: [@"com.macvoicemix.aggregate." stringByAppendingString:NSUUID.UUID.UUIDString],
            @kAudioAggregateDeviceIsPrivateKey: @YES,
            @kAudioAggregateDeviceMainSubDeviceKey: s->outputUID,
            @kAudioAggregateDeviceSubDeviceListKey: @[@{@kAudioSubDeviceUIDKey: s->outputUID, @kAudioSubDeviceInputChannelsKey: @0, @kAudioSubDeviceOutputChannelsKey: @2}],
            @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: tapUID, @kAudioSubTapDriftCompensationKey: @YES}],
        };
        check(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition, &s->aggregate), "Create private aggregate output failed");
        validateStreams(s->aggregate, kAudioObjectPropertyScopeOutput);
        validateStreams(s->aggregate, kAudioObjectPropertyScopeInput);
        if (channels(s->aggregate, kAudioObjectPropertyScopeOutput) != 2 || channels(s->aggregate, kAudioObjectPropertyScopeInput) != s->physicalInputs + 2)
            throw Failure("Unsupported", "Unexpected aggregate channel layout");
        check(AudioDeviceCreateIOProcID(s->aggregate, render, s, &s->io), "Create real-time callback failed");
        check(AudioDeviceStart(s->aggregate, s->io), "Start audio failed (check System Audio Recording permission)");
        s->started = true; context.permission = @"granted";
    } catch (...) {
        OSStatus cleanup = context.remove(app.key.UTF8String);
        if (cleanup) throw Failure("BackendFailure", "Audio setup failed and cleanup needs retry", cleanup);
        throw;
    }
}
id nullableNumber(AudioObjectID d, AudioObjectPropertySelector property, AudioObjectPropertyScope scope, const std::vector<UInt32> &elements, bool boolean = false) {
    if (elements.empty()) return NSNull.null;
    try {
        if (boolean) return @(read<UInt32>(d, property, scope, elements[0]) != 0);
        float max = 0; for (auto element : elements) max = std::max(max, read<Float32>(d, property, scope, element));
        return @(max);
    } catch (...) { return NSNull.null; }
}
NSDictionary *snapshot(Context &ctx) {
    auto apps = enumerateApps(); auto output = defaultOutput();
    NSString *outputUID = output ? stringProperty(output, kAudioDevicePropertyDeviceUID) : @"";
    double rate = 0;
    if (output) { try { rate = read<Float64>(output, kAudioDevicePropertyNominalSampleRate); } catch (...) {} }
    for (auto it = ctx.sessions.begin(); it != ctx.sessions.end();) {
        auto a = apps.find(it->first);
        const auto progress = it->second->callbacks.load(std::memory_order_relaxed);
        if (progress != it->second->observedCallbacks) {
            it->second->lastProgress = std::chrono::steady_clock::now(); it->second->observedCallbacks = progress;
        }
        bool stalled = std::chrono::steady_clock::now() - it->second->lastProgress > std::chrono::seconds(3);
        bool stale = stalled || rate != it->second->sampleRate || a == apps.end() || !a->second.compatible || a->second.processes != it->second->processes || ![it->second->outputUID isEqualToString:outputUID] || it->second->invalidBuffers.load() > 0;
        if (stale) {
            NSString *key = [NSString stringWithUTF8String:it->first.c_str()];
            OSStatus status = it->second->stop();
            ctx.errors[key] = status ? @"音频恢复失败，请重试恢复原声。" : @"音频进程或输出设备发生变化，已恢复原声；可以重新应用音量。";
            if (!status) { if (a == apps.end()) [ctx.errors removeObjectForKey:key]; it = ctx.sessions.erase(it); continue; }
        }
        ++it;
    }
    NSMutableArray *devices = [NSMutableArray array];
    for (auto d : objects(kAudioObjectSystemObject, kAudioHardwarePropertyDevices)) {
        NSString *uid = stringProperty(d, kAudioDevicePropertyDeviceUID);
        if ([uid hasPrefix:@"com.macvoicemix.aggregate."]) continue;
        for (NSString *direction in @[@"input", @"output"]) {
            bool input = [direction isEqualToString:@"input"]; auto scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
            if (!channels(d, scope)) continue;
            auto volumeControls = controls(d, kAudioDevicePropertyVolumeScalar, scope);
            auto muteControls = controls(d, kAudioDevicePropertyMute, scope);
            AudioObjectID defaultID = defaultDevice(input);
            [devices addObject:@{@"id": [uid stringByAppendingFormat:@"::%@", direction], @"uid":uid, @"name":stringProperty(d, kAudioObjectPropertyName), @"direction":direction, @"isDefault":@(defaultID == d), @"volume":nullableNumber(d,kAudioDevicePropertyVolumeScalar,scope,volumeControls), @"muted":nullableNumber(d,kAudioDevicePropertyMute,scope,muteControls,true), @"canSetVolume":@(!volumeControls.empty()), @"canMute":@(!muteControls.empty())}];
        }
    }
    NSMutableArray *applications = [NSMutableArray array];
    for (auto &[key, a] : apps) {
        auto session = ctx.sessions.find(key);
        Session *active = session == ctx.sessions.end() ? nullptr : session->second.get();
        NSString *reason = a.unsupportedReason;
        if (channels(output, kAudioObjectPropertyScopeOutput) != 2) reason = @"首版应用混音支持双声道默认输出设备。";
        [applications addObject:@{@"id":a.key, @"name":a.name, @"processCount":@(a.processes.size()),
            @"controllable":@(a.compatible && channels(output, kAudioObjectPropertyScopeOutput) == 2),
            @"unsupportedReason":reason ?: NSNull.null, @"controlled":@(active && active->started),
            @"error":ctx.errors[a.key] ?: NSNull.null, @"callbackCount":@(active ? active->callbacks.load() : 0),
            @"inputRms":@(active ? active->inputRms.load() : 0), @"outputRms":@(active ? active->outputRms.load() : 0),
            @"appliedGain":active ? @(active->appliedGain.load()) : NSNull.null}];
    }
    return @{@"devices":devices, @"apps":applications, @"capturePermission":ctx.permission, @"revision":@(++ctx.revision)};
}
NSDictionary *execute(Context &ctx, NSDictionary *request) {
    NSString *op = request[@"op"];
    if (![op isKindOfClass:NSString.class]) throw Failure("InvalidArgument", "Missing operation");
    if ([op isEqualToString:@"snapshot"]) return snapshot(ctx);
    if ([op isEqualToString:@"restore"] || [op isEqualToString:@"shutdown"]) { ctx.shutdown(); [ctx.errors removeAllObjects]; return [op isEqualToString:@"shutdown"] ? @{@"restored":@YES} : snapshot(ctx); }
    if ([op hasPrefix:@"device_"]) {
        NSString *uid = request[@"uid"]; NSString *direction = request[@"direction"];
        if (![uid isKindOfClass:NSString.class] || !uid.length || (! [direction isEqual:@"input"] && ![direction isEqual:@"output"])) throw Failure("InvalidArgument", "Invalid device identity or direction");
        auto device = resolveDevice(uid); bool input = [direction isEqual:@"input"]; auto scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
        if ([op isEqual:@"device_default"]) {
            // Restore taps before a default-output transition; user rules can be reapplied afterwards.
            if (!channels(device, scope)) throw Failure("Unsupported", "Device does not support the selected direction");
            if (!input) ctx.shutdown();
            write(kAudioObjectSystemObject, input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, device);
        } else if ([op isEqual:@"device_volume"]) {
            NSNumber *number = request[@"volume"];
            if (![number isKindOfClass:NSNumber.class] || !std::isfinite(number.floatValue) || number.floatValue < 0 || number.floatValue > 1) throw Failure("InvalidArgument", "Volume must be between zero and one");
            auto elements = controls(device, kAudioDevicePropertyVolumeScalar, scope);
            if (elements.empty()) throw Failure("Unsupported", "This device does not support system volume control");
            float previousMax = 0; std::vector<float> before;
            for (auto c : elements) { float v = read<Float32>(device, kAudioDevicePropertyVolumeScalar, scope, c); before.push_back(v); previousMax = std::max(previousMax,v); }
            try {
                for (size_t i=0;i<elements.size();++i) {
                    float value = elements.size() == 1 || previousMax == 0 ? number.floatValue : before[i] * number.floatValue / previousMax;
                    write(device,kAudioDevicePropertyVolumeScalar,value,scope,elements[i]);
                }
            } catch (...) {
                for (size_t i=0;i<elements.size();++i) { try { write(device,kAudioDevicePropertyVolumeScalar,before[i],scope,elements[i]); } catch (...) {} }
                throw;
            }
        } else if ([op isEqual:@"device_mute"]) {
            if (![request[@"muted"] isKindOfClass:NSNumber.class]) throw Failure("InvalidArgument", "Missing mute value");
            auto elements = controls(device,kAudioDevicePropertyMute,scope);
            if(elements.empty()) throw Failure("Unsupported","This device does not support mute");
            for(auto c:elements) write(device,kAudioDevicePropertyMute,UInt32([request[@"muted"] boolValue]),scope,c);
        } else throw Failure("InvalidArgument", "Unknown device operation");
        return snapshot(ctx);
    }
    if ([op isEqual:@"app_control"] || [op isEqual:@"app_reset"]) {
        NSString *key = request[@"appId"];
        if (![key isKindOfClass:NSString.class] || !key.length) throw Failure("InvalidArgument", "Invalid app identity");
        auto apps = enumerateApps(); auto app = apps.find(key.UTF8String);
        if ([op isEqual:@"app_reset"]) { check(ctx.remove(key.UTF8String),"Restore application audio failed"); [ctx.errors removeObjectForKey:key]; return snapshot(ctx); }
        NSNumber *volume = request[@"volume"], *muted = request[@"muted"];
        if (![volume isKindOfClass:NSNumber.class] || ![muted isKindOfClass:NSNumber.class] || !std::isfinite(volume.floatValue) || volume.floatValue < 0 || volume.floatValue > 1) throw Failure("InvalidArgument", "Invalid app volume or mute");
        if (app == apps.end()) throw Failure("SessionUnavailable", "Application is not currently producing audio");
        if (!app->second.compatible) throw Failure("Unsupported", "Application is not routed only to the default output");
        float gain = muted.boolValue ? 0 : volume.floatValue;
        if (gain == 1) check(ctx.remove(key.UTF8String), "Restore application audio failed");
        else {
            auto session = ctx.sessions.find(key.UTF8String);
            if (session == ctx.sessions.end()) createSession(ctx,app->second,gain);
            else {
                auto output = defaultOutput();
                double rate = output ? read<Float64>(output,kAudioDevicePropertyNominalSampleRate) : 0;
                if (!session->second->started || session->second->processes != app->second.processes || ![session->second->outputUID isEqualToString:stringProperty(output,kAudioDevicePropertyDeviceUID)] || rate != session->second->sampleRate) {
                    check(ctx.remove(key.UTF8String), "Restore stale application session failed");
                    createSession(ctx,app->second,gain);
                } else session->second->target.store(gain,std::memory_order_relaxed);
            }
        }
        [ctx.errors removeObjectForKey:key]; return snapshot(ctx);
    }
    throw Failure("InvalidArgument", "Unknown operation");
}
}
extern "C" void *mvm_create() { @autoreleasepool { try { return new Context; } catch (...) { return nullptr; } } }
extern "C" char *mvm_execute(void *context, const char *request_json) {
    @autoreleasepool {
        NSDictionary *result;
        @try {
        try {
            if (!context || !request_json) throw Failure("InvalidArgument", "Invalid native request");
            NSData *data = [NSData dataWithBytes:request_json length:strlen(request_json)];
            id request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![request isKindOfClass:NSDictionary.class]) throw Failure("InvalidArgument", "Expected JSON object");
            result = @{@"ok":@YES, @"data":execute(*static_cast<Context *>(context),request)};
        } catch (const Failure &e) {
            result = @{@"ok":@NO, @"error":@{@"code":[NSString stringWithUTF8String:e.code.c_str()], @"message":[NSString stringWithUTF8String:e.what()], @"platformCode":@(e.status)}};
        } catch (const std::exception &e) {
            result = @{@"ok":@NO, @"error":@{@"code":@"BackendFailure", @"message":[NSString stringWithUTF8String:e.what()]}};
        } catch (...) { result = @{@"ok":@NO,@"error":@{@"code":@"BackendFailure",@"message":@"Unexpected native error"}}; }
        } @catch (NSException *exception) {
            result = @{@"ok":@NO,@"error":@{@"code":@"BackendFailure",@"message":exception.reason ?: @"Native exception"}};
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        if (!json) return nullptr;
        char *out = static_cast<char *>(malloc(json.length + 1)); if (!out) return nullptr;
        memcpy(out,json.bytes,json.length); out[json.length]=0; return out;
    }
}
extern "C" void mvm_free(char *json) { free(json); }
extern "C" void mvm_destroy(void *context) {
    @autoreleasepool {
        if (!context) return;
        auto *ctx = static_cast<Context *>(context);
        try { ctx->shutdown(); delete ctx; }
        catch (...) { /* Preserve callback memory if HAL refuses cleanup. Process exit releases private resources. */ }
    }
}
