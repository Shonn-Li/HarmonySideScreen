#include "../entry/src/main/cpp/transfer_test.h"
#include <cassert>
#include <vector>
int main() {
    harmony::TransferTest t;
    try { t.begin(0,0); assert(false); } catch(const std::runtime_error&) {}
    std::vector<uint8_t> block(65536);
    for(size_t i=0;i<block.size();++i) block[i]=uint8_t(i*73+19);
    t.begin(t.bytes, 1);
    t.append(block.data(),block.size());
    assert(!t.valid() && t.mbps(2)==0);
    for(size_t n=block.size();n<t.bytes;n+=block.size()) t.append(block.data(),block.size());
    assert(t.valid()); assert(t.mbps(3)>67 && t.mbps(3)<68);
    try { t.append(block.data(),1); assert(false); } catch(const std::runtime_error&) {}
    t.begin(t.bytes, 4);
    block[999]^=1;
    for(size_t n=0;n<t.bytes;n+=block.size())t.append(block.data(),block.size());
    assert(!t.valid() && t.mbps(5)==0);
}
