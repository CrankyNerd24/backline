#pragma once

#include <array>
#include <atomic>
#include <cstddef>

namespace housekit {

// Lock-free single-producer/single-consumer ring buffer. Storage is inline,
// so push and pop never allocate. Holds Capacity - 1 items.
template <typename T, std::size_t Capacity>
class SPSCQueue {
    static_assert((Capacity & (Capacity - 1)) == 0, "Capacity must be a power of two");

public:
    bool push(const T &item) {
        const std::size_t head = head_.load(std::memory_order_relaxed);
        const std::size_t next = (head + 1) & (Capacity - 1);
        if (next == tail_.load(std::memory_order_acquire)) return false;
        items_[head] = item;
        head_.store(next, std::memory_order_release);
        return true;
    }

    bool pop(T &out) {
        const std::size_t tail = tail_.load(std::memory_order_relaxed);
        if (tail == head_.load(std::memory_order_acquire)) return false;
        out = items_[tail];
        tail_.store((tail + 1) & (Capacity - 1), std::memory_order_release);
        return true;
    }

private:
    std::array<T, Capacity> items_{};
    alignas(64) std::atomic<std::size_t> head_{0};
    alignas(64) std::atomic<std::size_t> tail_{0};
};

} // namespace housekit
