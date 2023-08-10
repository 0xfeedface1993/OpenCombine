//
//  Publishers._Merged.swift
//  
//
//  Created by Sergej Jaskiewicz on 03.12.2019.
//

import COpenCombineHelpers

extension Publishers {
    // swiftlint:disable:next type_name
    internal final class _Merged<Input, Failure, Downstream: Subscriber>
        : Subscription,
          CustomStringConvertible,
          CustomReflectable,
          CustomPlaygroundDisplayConvertible
        where Downstream.Input == Input, Downstream.Failure == Failure
    {
        private let downstream: Downstream
        private var demand = Subscribers.Demand.none // 0x78
        private var terminated = false // 0x80
        private let count: Int // 0x88
        private var upstreamFinished = 0 // 0x90
        private var finished = false // 0x98

        // TODO: The size of these arrays always stays the same.
        // Maybe we can leverage ManagedBuffer/ManagedBufferPointer here
        // to avoid additional allocations.
        private var subscriptions: [Subscription?] // 0xA0
        private var buffers: [Input?] // 0xA8

        private let lock = UnfairLock.allocate() // 0xB0
        private let downstreamLock = UnfairLock.allocate() // 0xB8
        private var recursive = false // 0xC0
        private var pending = Subscribers.Demand.none // 0xC8

        internal init(downstream: Downstream, count: Int) {
            self.downstream = downstream
            self.count = count
            self.subscriptions = Array(repeating: nil, count: count)
            self.buffers = Array(repeating: nil, count: count)
        }

        deinit {
            lock.deallocate()
            downstreamLock.deallocate()
        }

        private func receive(subscription: Subscription, _ index: Int) {
            lock.lock()
            guard subscriptions[index] == nil else {
                lock.unlock()
                subscription.cancel()
                return
            }
            subscriptions[index] = subscription
            let demand = self.demand
            lock.unlock()
            subscription.request(demand == .unlimited ? .unlimited : .max(1))
        }

        private func receive(_ input: Input, _ index: Int) -> Subscribers.Demand {
            func lockedSendValueDownstream() -> Subscribers.Demand {
                recursive = true
                lock.unlock()
                downstreamLock.lock()
                let newDemand = downstream.receive(input)
                downstreamLock.unlock()
                lock.lock()
                recursive = false
                return newDemand
            }

            lock.lock()
            if demand == .unlimited {
                let newDemand = lockedSendValueDownstream()
                lock.unlock()
                return newDemand
            }
            if demand == .none {
                buffers[index] = input
                lock.unlock()
                return .none
            }
            demand -= 1
            let newDemand = lockedSendValueDownstream()
            demand += newDemand + pending
            pending = .none
            lock.unlock()
            return .max(1)
        }

        private func receive(completion: Subscribers.Completion<Failure>, _ index: Int) {
            func lockedSendCompletionDownstream() {
                recursive = true
                lock.unlock()
                downstreamLock.lock()
                downstream.receive(completion: completion)
                downstreamLock.unlock()
                lock.lock()
                recursive = false
            }

            lock.lock()
            switch completion {
            case .finished:
                upstreamFinished += 1
                subscriptions[index] = nil
                // TODO: Test both conditions.
                // When receiving subscription twice, the second time
                // upstreamFinished != count
                guard upstreamFinished == count,
                      subscriptions.allSatisfy({ $0 == nil }) else {
                    lock.unlock()
                    return
                }
                finished = true
                lockedSendCompletionDownstream()
                lock.unlock()
            case .failure:
                if terminated {
                    lock.unlock()
                    return
                }
                terminated = true
                let subscriptions = self.subscriptions
                self.subscriptions = Array(repeating: nil, count: subscriptions.count)
                lock.unlock()
                for (i, subscription) in subscriptions.enumerated() where i != index {
                    subscription?.cancel()
                }
                lock.lock()
                lockedSendCompletionDownstream()
                lock.unlock()
            }
        }

        internal func request(_ demand: Subscribers.Demand) {
            lock.lock()
            // TODO: Test all conditions
            if terminated || finished || demand == .none || self.demand == .unlimited {
                lock.unlock()
                return
            }
            if recursive {
                pending += demand
                lock.unlock()
                return
            }
            if demand == .unlimited {
                // loc_6a5b1
                self.demand = .unlimited
            }
            
            if count == 0 {
                finished = true
                terminated = true
                downstream.receive(completion: .finished)
                lock.unlock()
                return
            }

            let subscriptions = self.subscriptions.compactMap({ $0 })
            let buffers = self.buffers.compactMap({ $0 })
            // TODO: Unimplemented
            
            func sendValueToDownstream(_ buffers: [Input?], action: (() -> Void)? = nil) {
                for value in buffers.compactMap({ $0 }) {
                    let newDemand = downstream.receive(value)
                    action?()
                    if newDemand == .none {
                        break
                    }
                }
            }
            
            func requestSubscriptions(_ subscriptions: [Subscription], demand: Subscribers.Demand) {
                subscriptions.forEach {
                    $0.request(demand)
                }
            }
            
            func validateNonZeroDemand(_ demand: Subscribers.Demand) -> Bool {
                guard let count = demand.max else {
                    return false
                }
                return count > 0
            }
            
            let bufferFilled = buffers.count > 0
            self.buffers = Array(repeating: nil, count: count)
            switch demand {
            case .unlimited:
                lock.unlock()
                if bufferFilled {
                    sendValueToDownstream(buffers)
                }
                requestSubscriptions(subscriptions, demand: demand)
            default:
                guard subscriptions.count > 0 else {
                    self.demand += demand
                    lock.unlock()
                    return
                }
                
                guard validateNonZeroDemand(demand) else {
                    lock.unlock()
                    return
                }
                
                var remaind = demand
                if bufferFilled {
                    sendValueToDownstream(buffers) {
                        remaind -= 1
                    }
                }
                
                defer {
                    lock.unlock()
                    requestSubscriptions(subscriptions, demand: .max(1))
                }
                
                guard validateNonZeroDemand(remaind) else {
                    return
                }
                
                self.demand += remaind
            }
        }

        internal func cancel() {
            // TODO: Unimplemented
            lock.lock()
            let subscriptions = self.subscriptions
            self.subscriptions = Array(repeating: nil, count: subscriptions.count)
            lock.unlock()
            
            subscriptions.forEach({ $0?.cancel() })
        }

        internal var description: String { return "Merge" }

        internal var customMirror: Mirror {
            return Mirror(self, children: EmptyCollection())
        }

        internal var playgroundDescription: Any { return description }
    }
}

extension Publishers._Merged {
    internal struct Side
        : Subscriber,
          CustomStringConvertible,
          CustomReflectable,
          CustomPlaygroundDisplayConvertible
    {
        private let index: Int
        private let merger: Publishers._Merged<Input, Failure, Downstream>

        internal let combineIdentifier = CombineIdentifier()

        internal init(index: Int,
                      merger: Publishers._Merged<Input, Failure, Downstream>) {
            self.index = index
            self.merger = merger
        }

        internal func receive(subscription: Subscription) {
            merger.receive(subscription: subscription, index)
        }

        internal func receive(_ input: Input) -> Subscribers.Demand {
            return merger.receive(input, index)
        }

        internal func receive(completion: Subscribers.Completion<Failure>) {
            merger.receive(completion: completion, index)
        }

        internal var description: String { return "Merge" }

        internal var customMirror: Mirror {
            let children = CollectionOfOne<Mirror.Child>(
                ("parentSubscription", merger.combineIdentifier)
            )
            return Mirror(self, children: children)
        }

        internal var playgroundDescription: Any { return description }
    }
}
