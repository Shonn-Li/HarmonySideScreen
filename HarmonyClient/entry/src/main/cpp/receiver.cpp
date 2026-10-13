// Copyright 2026 Shonn Li. MIT license.
// Native HarmonyOS surface decoder. USB data uses HDC rport, never ADB.
#include "wire.h"
#include "frame_rate.h"
#include "connection_health.h"
#include "transfer_test.h"
#include <sstream>
#include <napi/native_api.h>
#include <native_window/external_window.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <hilog/log.h>
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <cmath>
#include <cerrno>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

namespace {
// Request high refresh while streaming; the system retains the final refresh decision.
OH_NativeXComponent* videoComponent = nullptr; // accessed on the UI thread
bool highRefreshRequested = false;
void videoFrameTick(OH_NativeXComponent*, uint64_t, uint64_t) {}
void setVideoRefresh(bool enabled) {
    highRefreshRequested = enabled;
    if (!videoComponent) return;
    if (!enabled) {
        OH_NativeXComponent_UnregisterOnFrameCallback(videoComponent);
        return;
    }
    OH_NativeXComponent_ExpectedRateRange range{0,120,120};
    auto result = OH_NativeXComponent_SetExpectedFrameRateRange(videoComponent,&range);
    auto callback = OH_NativeXComponent_RegisterOnFrameCallback(videoComponent,videoFrameTick);
    OH_LOG_Print(LOG_APP,LOG_WARN,0x1100,"HarmonyScreen","Video surface high refresh: range=%{public}d callback=%{public}d",result,callback);
}
OH_NativeXComponent_Callback componentCallbacks{
    [](OH_NativeXComponent* c, void*) { videoComponent=c; setVideoRefresh(highRefreshRequested); },
    [](OH_NativeXComponent*, void*) {},
    [](OH_NativeXComponent* c, void*) {
        if (videoComponent==c) { setVideoRefresh(false); videoComponent=nullptr; }
    },
    [](OH_NativeXComponent*, void*) {}
};
struct Slot { uint32_t index; OH_AVBuffer* buffer; };
class Receiver {
public:
    ~Receiver() { stop(); }
    bool start(uint64_t surface, uint16_t port) {
        stop();
        if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(surface, &window_) != 0 || !window_) {
            setStatus("Cannot open display surface"); return false;
        }
        // Fit the complete desktop without distorting it when panel and stream ratios differ.
        OH_NativeWindow_NativeWindowSetScalingModeV2(window_, OH_SCALING_MODE_SCALE_FIT_V2);
        stopped_ = false; displayed_ = 0; frameRate_.reset(); placement_ = -1;
        linkMbps_ = -1; videoMbps_ = 0; rttMs_ = -1; testState_ = 0; testMbps_ = 0; testReceived_ = 0;
        worker_ = std::thread([this, port] { run(port); });
        return true;
    }
    void stop() {
        stopped_ = true;
        { std::lock_guard<std::mutex> lock(socketMutex_); if (fd_ >= 0) shutdown(fd_, SHUT_RDWR); }
        cv_.notify_all();
        if (worker_.joinable()) worker_.join();
        if (window_) { OH_NativeWindow_DestroyNativeWindow(window_); window_ = nullptr; }
        setStatus("Disconnected");
    }
    std::string status() { std::lock_guard<std::mutex> l(statusMutex_); return status_; }
    uint64_t frames() const { return displayed_; }
    double fps() { return stopped_ ? 0.0 : frameRate_.fps(); }
    bool running() const { return !stopped_; }
    int orientation() const { return orientation_; }
    int placement() const { return placement_; }
    bool place(int side, int alignment) {
        if (side < 0 || side > 3 || alignment < 0 || alignment > 2 || placement_ < 0) return false;
        uint8_t packet[3] = {16, uint8_t(0x80 | side), uint8_t(0x80 | alignment)};
        std::lock_guard<std::mutex> l(socketMutex_);
        return connected_ && sendPacketLocked(packet, sizeof(packet));
    }
    bool testConnection() {
        if (stopped_ || linkMbps_ < 0 || testState_ == 1 || testState_ == 2) return false;
        testState_=1; testMbps_=0; testReceived_=0; testRequestedAt_=now();
        const uint8_t query=20;
        std::lock_guard<std::mutex> lock(socketMutex_);
        if (!connected_ || !sendPacketLocked(&query,1)) { testState_=4; return false; }
        return true;
    }
    std::string diagnostics() {
        if ((testState_==1 || testState_==2) && now()-testRequestedAt_ > 20) testState_=4;
        std::ostringstream out;
        out << "{\"linkMbps\":" << linkMbps_.load() << ",\"videoMbps\":" << (now()-videoAt_ < 2 ? videoMbps_.load() : 0)
            << ",\"rttMs\":" << rttMs_.load() << ",\"testState\":" << testState_.load()
            << ",\"testMbps\":" << testMbps_.load() << ",\"testMB\":" << testReceived_/1048576.0
            << ",\"width\":" << outputWidth_.load() << ",\"height\":" << outputHeight_.load() << "}";
        return out.str();
    }
    void viewport(uint32_t w, uint32_t h, double dpiX, double dpiY) {
        if (w < 320 || h < 320 || w > 8192 || h > 8192 || uint64_t(w)*h > 32*1024*1024) return;
        auto dpi = [](double v) -> uint32_t { return std::isfinite(v) && v >= 50 && v <= 1000 ? uint32_t(std::round(v*10)) : 0; };
        uint32_t values[4] = {w,h,dpi(dpiX),dpi(dpiY)};
        std::lock_guard<std::mutex> l(socketMutex_);
        uint8_t packet[9] = {14};
        for (int i=0;i<4;++i) { packet[1+i*2] = 0x80 | (values[i] >> 7); packet[2+i*2] = 0x80 | (values[i] & 0x7f); }
        if (memcmp(viewport_,packet,9) == 0) return;
        memcpy(viewport_,packet,9);
        if (connected_) sendViewportLocked();
    }
    void touch(float x, float y, int32_t action) {
        if (stopped_ || x < 0 || x > 1 || y < 0 || y > 1 || action < 0 || action > 2) return;
        uint8_t packet[14] = {2,1}; // Wire touch payload is little endian on both supported hosts.
        memcpy(packet+2,&x,4); memcpy(packet+6,&y,4); memcpy(packet+10,&action,4);
        std::lock_guard<std::mutex> l(socketMutex_);
        if (fd_ >= 0) send(fd_,packet,sizeof(packet),MSG_NOSIGNAL);
    }
private:
    std::atomic<bool> stopped_{true};
    std::atomic<uint64_t> displayed_{0};
    harmony::FrameRate frameRate_;
    std::atomic<int> decoderError_{0};
    std::atomic<uint64_t> renderMicros_{0};
    double statsAt_ = 0;
    uint64_t statsInputs_ = 0, statsOutputs_ = 0;
    double statsInputWait_ = 0;
    std::thread worker_;
    std::mutex socketMutex_, statusMutex_, queueMutex_;
    std::condition_variable cv_;
    int fd_ = -1;
    bool connected_ = false; // guarded by socketMutex_
    uint8_t viewport_[9]{};
    std::atomic<int> orientation_{-1};
    std::atomic<int> placement_{-1};
    harmony::ConnectionHealth health_;
    std::atomic<int> linkMbps_{-1}, testState_{0};
    std::atomic<double> videoMbps_{0}, videoAt_{0}, rttMs_{-1}, testMbps_{0}, testRequestedAt_{0};
    std::atomic<uint32_t> testReceived_{0}, outputWidth_{0}, outputHeight_{0};
    uint64_t videoBytes_=0;
    double videoStarted_=0;
    void receiveTransferTest() {
        uint8_t header[4]; read(header,4);
        harmony::TransferTest test;
        test.begin(harmony::be32(header),now());
        testState_=2;
        uint8_t buffer[65536];
        while (test.received() < harmony::TransferTest::bytes) {
            read(buffer,sizeof(buffer)); test.append(buffer,sizeof(buffer)); testReceived_=test.received();
        }
        testMbps_=test.mbps(now()); testState_=test.valid() ? 3 : 4;
    }
    static double now() {
        return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
    }
    bool sendPacketLocked(const uint8_t* packet, size_t size) {
        size_t offset = 0;
        while (offset < size) {
            auto n = send(fd_,packet+offset,size-offset,MSG_NOSIGNAL);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { shutdown(fd_,SHUT_RDWR); return false; }
            offset += size_t(n);
        }
        return true;
    }
    void sendViewportLocked() {
        if (viewport_[0] != 14) return;
        sendPacketLocked(viewport_, sizeof(viewport_));
    }
    std::string status_ = "Ready";
    OHNativeWindow* window_ = nullptr;
    OH_AVCodec* decoder_ = nullptr;
    std::deque<Slot> slots_;
    uint32_t width_ = 0, height_ = 0;
    void setStatus(const std::string& value) { std::lock_guard<std::mutex> l(statusMutex_); status_ = value; }
    void read(void* dst, size_t size, bool idleAllowed = false) {
        auto p = static_cast<uint8_t*>(dst);
        while (size && !stopped_) {
            health_.check(now(), displayed_ > 0);
            if (health_.pingDue(now())) {
                uint8_t ping[9] = {4}; // Same monotonic clock at both ends of the round trip.
                uint64_t tick=uint64_t(now()*1e9);
                for (int i=0;i<8;++i) ping[1+i]=uint8_t(tick >> (56-i*8));
                std::lock_guard<std::mutex> l(socketMutex_);
                if (!sendPacketLocked(ping, sizeof(ping))) throw std::runtime_error("USB connection ended");
                health_.sentPing(now());
            }
            auto n = recv(fd_,p,size,0);
            if (n < 0 && errno == EINTR) continue;
            // A static desktop can legitimately send no new frames. Only wait
            // at a message boundary while heartbeat replies prove the Mac is alive.
            if (n < 0 && idleAllowed && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
            if (n <= 0) throw std::runtime_error("USB stream ended. Check Mac server and HDC connection.");
            health_.received(now());
            p += n; size -= size_t(n);
        }
        if (size) throw std::runtime_error("Disconnected");
    }
    static void error(OH_AVCodec*, int32_t code, void* user) {
        auto self = static_cast<Receiver*>(user);
        self->decoderError_ = code; self->cv_.notify_all();
    }
    static void changed(OH_AVCodec*, OH_AVFormat*, void*) {}
    static void input(OH_AVCodec*, uint32_t index, OH_AVBuffer* b, void* user) {
        auto self = static_cast<Receiver*>(user);
        { std::lock_guard<std::mutex> l(self->queueMutex_); self->slots_.push_back({index,b}); }
        self->cv_.notify_one();
    }
    static void output(OH_AVCodec* c, uint32_t index, OH_AVBuffer*, void* user) {
        auto self = static_cast<Receiver*>(user);
        if (self->stopped_) { OH_VideoDecoder_FreeOutputBuffer(c,index); return; }
        const auto began = now();
        // Present the newest decoded frame at the next vsync. Timestamped output
        // lets the compositor discard superseded frames instead of queueing lag.
        // A successful submission does not prove a physical panel refresh.
        const auto timestamp = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        auto rendered = OH_VideoDecoder_RenderOutputBufferAtTime(c,index,timestamp);
        self->renderMicros_.fetch_add(uint64_t((now()-began)*1000000));
        if (rendered == AV_ERR_OK) {
            ++self->displayed_;
            self->frameRate_.record();
            self->setStatus("Streaming over HDC USB");
        }
    }
    void releaseDecoder() {
        if (decoder_) { OH_VideoDecoder_Destroy(decoder_); decoder_ = nullptr; }
        // Destroy waits for callbacks; old slots must never reach the next decoder.
        std::lock_guard<std::mutex> l(queueMutex_); slots_.clear();
    }
    void configure(uint32_t w, uint32_t h) {
        if (decoder_ && w == width_ && h == height_) return;
        releaseDecoder(); width_ = w; height_ = h; decoderError_ = 0;
        decoder_ = OH_VideoDecoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_HEVC);
        if (!decoder_) throw std::runtime_error("This device cannot create an HEVC decoder");
        OH_AVCodecCallback cb{error, changed, input, output};
        if (OH_VideoDecoder_RegisterCallback(decoder_,cb,this) != AV_ERR_OK)
            throw std::runtime_error("Decoder callback setup failed");
        OH_AVFormat* format = OH_AVFormat_Create();
        if (!format) throw std::runtime_error("Decoder format allocation failed");
        OH_AVFormat_SetIntValue(format,OH_MD_KEY_WIDTH,int32_t(w));
        OH_AVFormat_SetIntValue(format,OH_MD_KEY_HEIGHT,int32_t(h));
        // Explicitly provision the decoder for high-refresh live video. The
        // stream's actual rate is still determined by arriving video frames.
        OH_AVFormat_SetDoubleValue(format,OH_MD_KEY_FRAME_RATE,120.0);
        OH_AVFormat_SetIntValue(format,OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY,1);
        if (auto capability = OH_AVCodec_GetCapabilityByCategory(OH_AVCODEC_MIMETYPE_VIDEO_HEVC,false,HARDWARE)) {
            OH_AVRange rates{};
            if (OH_AVCapability_GetVideoFrameRateRangeForSize(capability,int32_t(w),int32_t(h),&rates) == AV_ERR_OK) {
                OH_LOG_Print(LOG_APP,LOG_WARN,0x1100,"HarmonyScreen","HEVC decoder capability %{public}ux%{public}u: %{public}d..%{public}d FPS",w,h,rates.minVal,rates.maxVal);
            }
        }
        auto configured = OH_VideoDecoder_Configure(decoder_,format);
        OH_AVFormat_Destroy(format);
        if (configured != AV_ERR_OK || OH_VideoDecoder_SetSurface(decoder_,window_) != AV_ERR_OK ||
            OH_VideoDecoder_Prepare(decoder_) != AV_ERR_OK || OH_VideoDecoder_Start(decoder_) != AV_ERR_OK)
            throw std::runtime_error("Decoder setup failed; try 1920 x 1200 at 30 FPS on the Mac");
        setStatus("Connected; waiting for first decoded frame");
    }
    void decode(const std::vector<uint8_t>& frame) {
        if (!decoder_) throw std::runtime_error("Video arrived before display configuration");
        const auto began = now();
        std::unique_lock<std::mutex> l(queueMutex_);
        bool ready = cv_.wait_for(l,std::chrono::seconds(2),[this] { return stopped_ || decoderError_ || !slots_.empty(); });
        if (!ready || decoderError_) throw std::runtime_error("Video decoder stalled or rejected the stream");
        if (stopped_) throw std::runtime_error("Disconnected");
        Slot s = slots_.front(); slots_.pop_front(); l.unlock();
        statsInputWait_ += now()-began;
        auto capacity = OH_AVBuffer_GetCapacity(s.buffer);
        auto address = OH_AVBuffer_GetAddr(s.buffer);
        if (!address || capacity < 0 || frame.size() > size_t(capacity))
            throw std::runtime_error("Encoded frame exceeds decoder buffer capacity");
        memcpy(address,frame.data(),frame.size());
        OH_AVCodecBufferAttr attr{};
        attr.pts = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
        attr.size = int32_t(frame.size()); attr.offset = 0; attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
        if (OH_AVBuffer_SetBufferAttr(s.buffer,&attr) != AV_ERR_OK || OH_VideoDecoder_PushInputBuffer(decoder_,s.index) != AV_ERR_OK)
            throw std::runtime_error("Decoder rejected a video frame");
        ++statsInputs_;
        const auto elapsed = now()-statsAt_;
        if (elapsed >= 5) {
            auto outputs = displayed_.load();
            auto rendered = outputs-statsOutputs_;
            auto micros = renderMicros_.exchange(0);
            OH_LOG_Print(LOG_APP,LOG_WARN,0x1100,"HarmonyScreen","Video pipeline: input %{public}.1f FPS, output %{public}.1f FPS, input wait %{public}.2f ms, surface submit %{public}.2f ms",statsInputs_/elapsed,rendered/elapsed,statsInputWait_*1000/statsInputs_,rendered ? double(micros)/rendered/1000 : 0.0);
            statsAt_=now(); videoStarted_=now(); videoBytes_=0; statsInputs_=0; statsOutputs_=outputs; statsInputWait_=0;
        }
    }
    void run(uint16_t port) {
        try {
            statsAt_=now(); videoStarted_=now(); videoBytes_=0; statsInputs_=0; statsOutputs_=0; statsInputWait_=0; renderMicros_=0;
            setStatus("Connecting to Mac through HDC…");
            { std::lock_guard<std::mutex> l(socketMutex_); fd_ = socket(AF_INET,SOCK_STREAM,0); }
            if (fd_ < 0) throw std::runtime_error("Could not create stream socket");
            timeval timeout{2,0};
            setsockopt(fd_,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
            setsockopt(fd_,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
            int one = 1; setsockopt(fd_,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
            setsockopt(fd_,SOL_SOCKET,SO_KEEPALIVE,&one,sizeof(one));
            sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(port);
            address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            if (connect(fd_,reinterpret_cast<sockaddr*>(&address),sizeof(address)) != 0)
                throw std::runtime_error("Mac unreachable. Start HarmonyScreen and verify its HDC tunnel is ready.");
            health_.start(now());
            {
                std::lock_guard<std::mutex> l(socketMutex_);
                connected_ = true; sendViewportLocked();
                const uint8_t diagnostics=18;
                sendPacketLocked(&diagnostics,1);
                const uint8_t query[3] = {16, 0xff, 0xff};
                sendPacketLocked(query, sizeof(query));
            }
            // Keep the first preview on the upstream legacy video framing (HEVC).
            while (!stopped_) {
                uint8_t type; read(&type,1,true);
                if (type == 1) {
                    uint8_t data[12]; read(data,sizeof(data));
                    auto w = harmony::be32(data), h = harmony::be32(data+4);
                    harmony::validateDisplay(w,h,harmony::be32(data+8)); configure(w,h);
                    outputWidth_=w; outputHeight_=h;
                } else if (type == 0 || type == 6) {
                    uint8_t header[4]; read(header,4); auto size = harmony::frameLength(header);
                    if (type == 6) { uint8_t metadata[9]; read(metadata,9); }
                    std::vector<uint8_t> frame(size); read(frame.data(),frame.size());
                    videoBytes_ += size;
                    const double stamp=now();
                    if (stamp-videoStarted_ >= 0.5) {
                        videoMbps_=videoBytes_*8.0/(stamp-videoStarted_)/1e6; videoAt_=stamp;
                        videoBytes_=0; videoStarted_=stamp;
                    }
                    decode(frame);
                } else if (type == 19) {
                    uint8_t data[4]; read(data,4); linkMbps_=int(harmony::be32(data));
                } else if (type == 21) {
                    receiveTransferTest();
                } else if (type == 5 || type == 13) {
                    uint8_t data[8]; read(data,8);
                    if (type==5) {
                        uint64_t tick=0; for (auto byte:data) tick=(tick<<8)|byte;
                        double ms=(now()-double(tick)/1e9)*1000;
                        if (tick && ms >= 0 && ms < 20000) rttMs_=ms;
                    }
                } else if (type == 15) {
                    uint8_t value; read(&value,1);
                    if (value > 2) throw std::runtime_error("Invalid phone orientation");
                    orientation_ = value;
                } else if (type == 17) {
                    uint8_t value[2]; read(value,2);
                    if (value[0] < 0x80 || value[0] > 0x83 || value[1] < 0x80 || value[1] > 0x82)
                        throw std::runtime_error("Invalid screen position from Mac");
                    placement_ = (value[0] & 0x7f) * 3 + (value[1] & 0x7f);
                } else if (type == 10) {
                    uint8_t codec; read(&codec,1);
                    if (codec != 0) throw std::runtime_error("This preview requires HEVC");
                } else throw std::runtime_error("Unsupported stream protocol message");
            }
        } catch (const std::exception& e) { setStatus(e.what()); }
        stopped_ = true;
        if (testState_==1 || testState_==2) testState_=4;
        cv_.notify_all(); releaseDecoder();
        { std::lock_guard<std::mutex> l(socketMutex_); if (fd_ >= 0) close(fd_); fd_ = -1; connected_ = false; }
    }
};
Receiver receiver;
napi_value Start(napi_env env,napi_callback_info info) {
    size_t count = 2; napi_value args[2]; napi_get_cb_info(env,info,&count,args,nullptr,nullptr);
    bool result = false;
    if (count == 2) {
        char id[32]{}; size_t length = 0; uint32_t port = 0;
        if (napi_get_value_string_utf8(env,args[0],id,sizeof(id),&length) == napi_ok &&
            napi_get_value_uint32(env,args[1],&port) == napi_ok && port >= 1024 && port <= 65535) {
            try { result = receiver.start(std::stoull(id),uint16_t(port)); } catch (...) { result = false; }
            setVideoRefresh(result);
        }
    }
    napi_value value; napi_get_boolean(env,result,&value); return value;
}
napi_value Stop(napi_env env,napi_callback_info) { setVideoRefresh(false); receiver.stop(); napi_value v; napi_get_undefined(env,&v); return v; }
napi_value Status(napi_env env,napi_callback_info) { napi_value v; auto s = receiver.status(); napi_create_string_utf8(env,s.c_str(),s.size(),&v); return v; }
napi_value Frames(napi_env env,napi_callback_info) { napi_value v; napi_create_double(env,double(receiver.frames()),&v); return v; }
napi_value FPS(napi_env env,napi_callback_info) { napi_value v; napi_create_double(env,receiver.fps(),&v); return v; }
napi_value Running(napi_env env,napi_callback_info) {
    const bool running = receiver.running();
    if (!running && highRefreshRequested) setVideoRefresh(false);
    napi_value v; napi_get_boolean(env,running,&v); return v;
}
napi_value Diagnostics(napi_env env,napi_callback_info) { napi_value v; auto s=receiver.diagnostics(); napi_create_string_utf8(env,s.c_str(),s.size(),&v); return v; }
napi_value TestConnection(napi_env env,napi_callback_info) { napi_value v; napi_get_boolean(env,receiver.testConnection(),&v); return v; }
napi_value Orientation(napi_env env,napi_callback_info) { napi_value v; napi_create_int32(env,receiver.orientation(),&v); return v; }
napi_value Placement(napi_env env,napi_callback_info) { napi_value v; napi_create_int32(env,receiver.placement(),&v); return v; }
napi_value Place(napi_env env,napi_callback_info info) {
    size_t count=2; napi_value args[2]; napi_get_cb_info(env,info,&count,args,nullptr,nullptr);
    int32_t side=-1, alignment=-1; bool result=false;
    if (count==2 && napi_get_value_int32(env,args[0],&side)==napi_ok && napi_get_value_int32(env,args[1],&alignment)==napi_ok)
        result=receiver.place(side,alignment);
    napi_value v; napi_get_boolean(env,result,&v); return v;
}
napi_value Viewport(napi_env env,napi_callback_info info) {
    size_t count=4; napi_value args[4]; napi_get_cb_info(env,info,&count,args,nullptr,nullptr);
    uint32_t w=0,h=0; double x=0,y=0;
    if (count==4 && napi_get_value_uint32(env,args[0],&w)==napi_ok && napi_get_value_uint32(env,args[1],&h)==napi_ok &&
        napi_get_value_double(env,args[2],&x)==napi_ok && napi_get_value_double(env,args[3],&y)==napi_ok) receiver.viewport(w,h,x,y);
    napi_value v; napi_get_undefined(env,&v); return v;
}
napi_value Touch(napi_env env,napi_callback_info info) {
    size_t count=3; napi_value args[3]; napi_get_cb_info(env,info,&count,args,nullptr,nullptr);
    double x=0,y=0; int32_t action=0;
    if (count==3 && napi_get_value_double(env,args[0],&x)==napi_ok && napi_get_value_double(env,args[1],&y)==napi_ok && napi_get_value_int32(env,args[2],&action)==napi_ok)
        receiver.touch(float(x),float(y),action);
    napi_value v; napi_get_undefined(env,&v); return v;
}
napi_value Init(napi_env env,napi_value exports) {
    bool hasComponent = false;
    napi_value componentValue;
    OH_NativeXComponent* component = nullptr;
    if (napi_has_named_property(env,exports,OH_NATIVE_XCOMPONENT_OBJ,&hasComponent)==napi_ok && hasComponent &&
        napi_get_named_property(env,exports,OH_NATIVE_XCOMPONENT_OBJ,&componentValue)==napi_ok &&
        napi_unwrap(env,componentValue,reinterpret_cast<void**>(&component))==napi_ok && component) {
        OH_NativeXComponent_RegisterCallback(component,&componentCallbacks);
    }
    napi_property_descriptor methods[] = {
        {"start",nullptr,Start,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"stop",nullptr,Stop,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"status",nullptr,Status,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"frames",nullptr,Frames,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"fps",nullptr,FPS,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"diagnostics",nullptr,Diagnostics,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"testConnection",nullptr,TestConnection,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"running",nullptr,Running,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"viewport",nullptr,Viewport,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"orientation",nullptr,Orientation,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"placement",nullptr,Placement,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"place",nullptr,Place,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"touch",nullptr,Touch,nullptr,nullptr,nullptr,napi_default,nullptr}};
    napi_define_properties(env,exports,sizeof(methods)/sizeof(methods[0]),methods); return exports;
}
napi_module module = {1,0,nullptr,Init,"harmonyscreen",nullptr,{0}};
}
extern "C" __attribute__((constructor)) void RegisterHarmonyScreen() { napi_module_register(&module); }
