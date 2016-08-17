//
//  Document.swift
//  BSON
//
//  Created by Robbert Brandsma on 19-05-16.
//
//

import Foundation

public protocol BSONArrayProtocol : _ArrayProtocol {}
extension Array : BSONArrayProtocol {}

extension BSONArrayProtocol where Iterator.Element == Document {
    public init(bsonBytes bytes: [UInt8], validating: Bool = false) {
        var array = [Document]()
        var position = 0
        
        documentLoop: while bytes.count >= position + 5 {
            let length = Int(UnsafePointer<Int32>(Array(bytes[position..<position+4])).pointee)
            
            guard length > 0 else {
                // invalid
                break
            }
            
            guard bytes.count >= position + length else {
                break documentLoop
            }
            
            let document = Document(data: Array(bytes[position..<position+length]))
            
            if validating {
                if document.validate() {
                    array.append(document)
                }
            } else {
                array.append(document)
            }
            
            position += length
        }
        
        self.init(array)
    }
    
    /// The combined data for all documents in the array
    public var bytes: [UInt8] {
        return self.map { $0.bytes }.reduce([], +)
    }
}

internal enum ElementType : UInt8 {
    case double = 0x01
    case string = 0x02
    case document = 0x03
    case arrayDocument = 0x04
    case binary = 0x05
    case objectId = 0x07
    case boolean = 0x08
    case utcDateTime = 0x09
    case nullValue = 0x0A
    case regex = 0x0B
    case javascriptCode = 0x0D
    case javascriptCodeWithScope = 0x0F
    case int32 = 0x10
    case timestamp = 0x11
    case int64 = 0x12
    case minKey = 0xFF
    case maxKey = 0x7F
}

/// `Document` is a collection type that uses a BSON document as storage.
/// As such, it can be stored in a file or instantiated from BSON data.
/// 
/// Documents behave partially like an array, and partially like a dictionary.
/// For general information about BSON documents, see http://bsonspec.org/spec.html
public struct Document : Collection, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    internal var storage: [UInt8]
    internal var _count: Int? = nil
    internal var invalid = false
    internal var elementPositions = [Int]()
    
    // MARK: - Initialization from data
    
    /// Initializes this Doucment with binary `Foundation.Data`
    ///
    /// - parameters data: the `Foundation.Data` that's being used to initialize this`Document`
    public init(data: Foundation.Data) {
        var byteArray = [UInt8](repeating: 0, count: data.count)
        data.copyBytes(to: &byteArray, count: byteArray.count)
        
        self.init(data: byteArray)
    }
    
    /// Initializes this Doucment with an `Array` of `Byte`s - I.E: `[Byte]`
    ///
    /// - parameters data: the `[Byte]` that's being used to initialize this `Document`
    public init(data: [UInt8]) {
        guard let length = try? Int32.instantiate(bytes: Array(data[0...3])), Int(length) <= data.count else {
            self.storage = [5,0,0,0,0]
            self.invalid = true
            return
        }
        
        storage = Array(data[0..<Int(length)])
        elementPositions = buildElementPositionsCache()
    }
    
    /// Initializes this Doucment with an `Array` of `Byte`s - I.E: `[Byte]`
    ///
    /// - parameters data: the `[Byte]` that's being used to initialize this `Document`
    public init(data: ArraySlice<UInt8>) {
        guard let length = try? Int32.instantiate(bytes: Array(data[0...3])), Int(length) <= data.count else {
            self.storage = [5,0,0,0,0]
            self.invalid = true
            return
        }
        
        storage = Array(data[0..<Int(length)])
        elementPositions = buildElementPositionsCache()
    }
    
    /// Initializes an empty `Document`
    public init() {
        // the empty document is 5 bytes long.
        storage = [5,0,0,0,0]
    }
    
    // MARK: - Initialization from Swift Types & Literals
    
    /// Initializes this `Document` as a `Dictionary` using an existing Swift `Dictionary`
    ///
    /// - parameter elements: The `Dictionary`'s generics used to initialize this must be a `String` key and `Value` for the value
    public init(dictionaryElements elements: [(String, Value)]) {
        self.init()
        for element in elements {
            self.append(element.1, forKey: element.0)
        }
    }
    
    /// Initializes this `Document` as a `Dictionary` using a `Dictionary` literal
    ///
    /// - parameter elements: The `Dictionary` used to initialize this must use `String` for key and `Value` for values
    public init(dictionaryLiteral elements: (String, Value)...) {
        self.init(dictionaryElements: elements)
    }
    
    /// Initializes this `Document` as an `Array` using an `Array` literal
    ///
    /// - parameter elements: The `Array` literal used to initialize the `Document` must be a `[Value]`
    public init(arrayLiteral elements: Value...) {
        self.init(array: elements)
    }
    
    /// Initializes this `Document` as an `Array` using an `Array` literal
    ///
    /// - parameter elements: The `Array` used to initialize the `Document` must be a `[Value]`
    public init(array elements: [Value]) {
        self.init(dictionaryElements: elements.enumerated().map { (index, value) in ("\(index)", value) })
    }
    
    // MARK: - Manipulation & Extracting values
    
    public typealias Index = DocumentIndex
    public typealias IndexIterationElement = (key: String, value: Value)
    
    /// Appends a Key-Value pair to this `Document` where this `Document` acts like a `Dictionary`
    ///
    /// TODO: Analyze what should happen with `Array`-like documents and this function
    /// TODO: Analyze what happens when you append with a duplicate key
    ///
    /// - parameter value: The `Value` to append
    /// - parameter key: The key in the key-value pair
    public mutating func append(_ value: Value, forKey key: String) {
        var buffer = [UInt8]()
        
        // First, the type
        buffer.append(value.typeIdentifier)
        
        // Then, the key name
        buffer += key.utf8 + [0x00]
        
        // Lastly, the data
        buffer += value.bytes
        
        elementPositions.append(storage.endIndex-1)
        
        // Then, insert it into ourselves, before the ending 0-byte.
        storage.insert(contentsOf: buffer, at: storage.endIndex-1)
        
        // Increase the bytecount
        updateDocumentHeader()
    }
    
    /// Appends a `Value` to this `Document` where this `Document` acts like an `Array`
    ///
    /// TODO: Analyze what should happen with `Dictionary`-like documents and this function
    ///
    /// - parameter value: The `Value` to append
    public mutating func append(_ value: Value) {
        let key = "\(self.count)"
        self.append(value, forKey: key)
    }
    
    /// Updates this `Document`'s storage to contain the proper `Document` length header
    internal mutating func updateDocumentHeader() {
        storage.replaceSubrange(0..<4, with: Int32(storage.count).bytes)
    }
    
    // MARK: - Collection
    
    /// The first `Index` in this `Document`. Can point to nothing when the `Document` is empty
    public var startIndex: DocumentIndex {
        return DocumentIndex(byteIndex: 4)
    }
    
    /// The last `Index` in this `Document`. Can point to nothing whent he `Document` is empty
    public var endIndex: DocumentIndex {
        var thisIndex = 4
        for element in self.makeKeyIterator() {
            thisIndex = element.startPosition
        }
        return DocumentIndex(byteIndex: thisIndex)
    }
    
    /// Creates an iterator that iterates over all key-value pairs
    public func makeIterator() -> AnyIterator<IndexIterationElement> {
        let keys = self.makeKeyIterator()
        
        return AnyIterator {
            guard let key = keys.next() else {
                return nil
            }

            guard let string = String(bytes: key.keyData[0..<key.keyData.endIndex-1], encoding: String.Encoding.utf8) else {
                return nil
            }
            
            let value = self.getValue(atDataPosition: key.dataPosition, withType: key.type)
            
            return IndexIterationElement(key: string, value: value)
        }
    }
    
    /// Fetches the next index
    ///
    /// - parameter i: The `Index` to advance
    public func index(after i: DocumentIndex) -> DocumentIndex {
        var position = i.byteIndex
        
        guard let type = ElementType(rawValue: storage[position]) else {
            fatalError("Invalid type found in Document when finding the next key at position \(position)")
        }
        
        position += 1
        
        while storage[position] != 0 {
            position += 1
        }
        
        position += 1
        
        let length = getLengthOfElement(withDataPosition: position, type: type)
        
        // Return the position of the byte after the value
        return DocumentIndex(byteIndex: position + length)
    }
    
    // MARK: - The old API had this...
    
    /// Finds the key-value pair for the given key and removes it
    ///
    /// - parameter key: The `key` in the key-value pair to remove
    ///
    /// - returns: The `Value` in the pair if there was any
    @discardableResult public mutating func removeValue(forKey key: String) -> Value? {
        guard let meta = getMeta(forKeyBytes: [UInt8](key.utf8)) else {
            return nil
        }
        
        let val = getValue(atDataPosition: meta.dataPosition, withType: meta.type)
        let length = getLengthOfElement(withDataPosition: meta.dataPosition, type: meta.type)
        
        storage.removeSubrange(meta.elementTypePosition..<meta.dataPosition + length)
        
        let removedLength = (meta.dataPosition + length) - meta.elementTypePosition
        
        for (index, element) in elementPositions.enumerated() where element > meta.elementTypePosition {
            elementPositions[index] = elementPositions[index] - removedLength
        }
        
        if let index = elementPositions.index(of: meta.elementTypePosition) {
            elementPositions.remove(at: index)
        }
        
        updateDocumentHeader()
        
        return val
    }
    
    // MARK: - Files
    
    /// Writes this `Document` to a file. Usually for debugging purposes
    ///
    /// - parameter path: The path to write this to
    public func write(toFile path: String) throws {
        var myData = storage
        let nsData = NSData(bytes: &myData, length: myData.count)
        
        try nsData.write(toFile: path)
    }
}

public struct DocumentIndex : Comparable {
    // The byte index is the very start of the element, the element type
    internal var byteIndex: Int
    
    internal init(byteIndex: Int) {
        self.byteIndex = byteIndex
    }
    
    public static func ==(lhs: DocumentIndex, rhs: DocumentIndex) -> Bool {
        return lhs.byteIndex == rhs.byteIndex
    }
    
    public static func <(lhs: DocumentIndex, rhs: DocumentIndex) -> Bool {
        return lhs.byteIndex < rhs.byteIndex
    }
}

extension Sequence where Iterator.Element == Document {
    /// Converts a sequence of Documents to an array of documents in BSON format
    public func makeDocument() -> Document {
        var combination = Document()
        for doc in self {
            combination.append(~doc)
        }
        
        return combination
    }
}

