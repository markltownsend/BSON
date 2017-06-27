import KittenCore

struct IndexKey: Hashable {
    let key: KittenBytes
    let hashValue: Int
    
    init(_ key: KittenBytes) {
        self.key = key
        self.hashValue = key.hashValue
    }
    
    static func ==(lhs: IndexKey, rhs: IndexKey) -> Bool {
        return lhs.hashValue == rhs.hashValue
    }
    
    var s: String {
        return String(bytes: key.bytes, encoding: .utf8)!
    }
}

class IndexTrieNode {
    var storage = Dictionary<IndexKey, IndexTrieNode>()
    var value: Int
    var fullyIndexed: Bool = false
    
    init(_ value: Int) {
        self.value = value
    }
    
    subscript(position path: [IndexKey]) -> Int? {
        get {
            var position = 0
            var iterator = path.makeIterator()
            
            guard let first = iterator.next() else {
                return nil
            }
            
            guard var node: IndexTrieNode = storage[first] else {
                return nil
            }
            
            position += node.value
            var previousComponentLength: Int = first.key.bytes.count
            
            while let component = iterator.next() {
                guard let subNode = node.storage[component] else {
                    return nil
                }
                
                node = subNode
                
                position += subNode.value &+ 6 &+ previousComponentLength
                
                previousComponentLength = component.key.bytes.count
            }
            
            return position
        }
    }
    
    subscript(_ path: [IndexKey]) -> IndexTrieNode? {
        get {
            var iterator = path.makeIterator()
            
            guard let first = iterator.next() else {
                return nil
            }
            
            guard var node: IndexTrieNode = storage[first] else {
                return nil
            }
            
            while let component = iterator.next() {
                guard let subNode = node.storage[component] else {
                    return nil
                }
                
                node = subNode
            }
            
            return node
        }
        set {
            var iterator = path.makeIterator()
            
            guard let newValue = newValue else {
                guard let first = iterator.next() else {
                    return
                }
                
                var node: IndexTrieNode? = self.storage[first]
                
                func mutate(_ node: inout IndexTrieNode?) {
                    if node != nil, let next = iterator.next() {
                        var newNode = node?.storage[next]
                        
                        mutate(&newNode)
                        
                        node?.storage[next] = newNode
                    } else {
                        node = nil
                    }
                }
                
                mutate(&node)
                
                self.storage[first] = node
                return
            }
            
            var node: IndexTrieNode = self
            var last: IndexKey?
            
            while let next = iterator.next() {
                last = next
                guard let nextNode = node.storage[next] else {
                    guard iterator.next() == nil else {
                        return
                    }
                    
                    node.storage[next] = newValue
                    return
                }
                
                node = nextNode
            }
            
            if let last = last {
                node.storage[last] = newValue
            }
        }
    }
}