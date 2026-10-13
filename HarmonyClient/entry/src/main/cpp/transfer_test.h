#pragma once
#include <cstdint>
#include <cstddef>
#include <stdexcept>
namespace harmony {
class TransferTest {
public:
    static constexpr uint32_t bytes = 16 * 1024 * 1024;
    void begin(uint32_t size, double now) {
        if (size != bytes) throw std::runtime_error("Invalid transfer test size");
        received_ = 0; valid_ = true; started_ = now;
    }
    void append(const uint8_t* data, size_t size) {
        if (size > bytes - received_) throw std::runtime_error("Transfer test overflow");
        for (size_t i = 0; i < size; ++i)
            if (data[i] != uint8_t((received_ + i) * 73 + 19)) valid_ = false;
        received_ += size;
    }
    bool valid() const { return valid_ && received_ == bytes; }
    uint32_t received() const { return received_; }
    double mbps(double now) const { return valid() && now > started_ ? received_ * 8.0 / (now-started_) / 1e6 : 0; }
private:
    uint32_t received_ = 0;
    bool valid_ = false;
    double started_ = 0;
};
}
