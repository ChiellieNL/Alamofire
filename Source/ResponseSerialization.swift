//
//  ResponseSerialization.swift
//
//  Copyright (c) 2014-2018 Alamofire Software Foundation (http://alamofire.org/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

// MARK: Protocols

/// The type to which all data response serializers must conform in order to serialize a response.
public protocol DataResponseSerializerProtocol {
    /// The type of serialized object to be created by this serializer.
    associatedtype SerializedObject

    /// The function used to serialize the response data in response handlers.
    func serialize(request: URLRequest?, response: HTTPURLResponse?, data: Data?, error: Error?) throws -> SerializedObject
}

/// The type to which all download response serializers must conform in order to serialize a response.
public protocol DownloadResponseSerializerProtocol {
    /// The type of serialized object to be created by this `DownloadResponseSerializerType`.
    associatedtype SerializedObject

    /// The function used to serialize the downloaded data in response handlers.
    func serializeDownload(request: URLRequest?, response: HTTPURLResponse?, fileURL: URL?, error: Error?) throws -> SerializedObject
}

/// A serializer that can handle both data and download responses.
public protocol ResponseSerializer: DataResponseSerializerProtocol & DownloadResponseSerializerProtocol {
    var emptyRequestMethods: Set<HTTPMethod> { get }
    var emptyResponseCodes: Set<Int> { get }
}

extension ResponseSerializer {
    public static var defaultEmptyRequestMethods: Set<HTTPMethod> { return [.head] }
    public static var defaultEmptyResponseCodes: Set<Int> { return [204, 205] }

    var emptyRequestMethods: Set<HTTPMethod> { return Self.defaultEmptyRequestMethods }
    var emptyResponseCodes: Set<Int> { return Self.defaultEmptyResponseCodes }

    public func requestAllowsEmptyResponseData(_ request: URLRequest?) -> Bool? {
        return request.flatMap { $0.httpMethod }
                      .flatMap(HTTPMethod.init)
                      .map { emptyRequestMethods.contains($0) }
    }

    public func responseAllowsEmptyResponseData(_ response: HTTPURLResponse?) -> Bool? {
        return response.flatMap { $0.statusCode }
                       .map { emptyResponseCodes.contains($0) }
    }

    public func emptyResponseAllowed(forRequest request: URLRequest?, response: HTTPURLResponse?) -> Bool {
        return requestAllowsEmptyResponseData(request) ?? responseAllowsEmptyResponseData(response) ?? false
    }
}

/// By default, any serializer declared to conform to both types will get file serialization for free, as it just feeds
/// the data read from disk into the data response serializer.
public extension DownloadResponseSerializerProtocol where Self: DataResponseSerializerProtocol {
    public func serializeDownload(request: URLRequest?, response: HTTPURLResponse?, fileURL: URL?, error: Error?) throws -> Self.SerializedObject {
        guard error == nil else { throw error! }

        guard let fileURL = fileURL else {
            throw AFError.responseSerializationFailed(reason: .inputFileNil)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw AFError.responseSerializationFailed(reason: .inputFileReadFailed(at: fileURL))
        }

        do {
            return try serialize(request: request, response: response, data: data, error: error)
        } catch {
            throw error
        }
    }
}

// MARK: - Default

extension DataRequest {
    /// Adds a handler to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:             The queue on which the completion handler is dispatched. Defaults to `nil`, which means
    ///                        the handler is called on `.main`.
    ///   - completionHandler: The code to be executed once the request has finished.
    /// - Returns:             The request.
    @discardableResult
    public func response(queue: DispatchQueue? = nil, completionHandler: @escaping (DataResponse<Data?>) -> Void) -> Self {
        internalQueue.addOperation {
            self.serializationQueue.async {
                let result = Result(value: self.data, error: self.error)
                let response = DataResponse(request: self.request,
                                            response: self.response,
                                            data: self.data,
                                            metrics: self.metrics,
                                            serializationDuration: 0,
                                            result: result)

                self.eventMonitor?.request(self, didParseResponse: response)

                (queue ?? .main).async { completionHandler(response) }
            }
        }

        return self
    }

    /// Adds a handler to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:              The queue on which the completion handler is dispatched. Defaults to `nil`, which means
    ///                         the handler is called on `.main`.
    ///   - responseSerializer: The response serializer responsible for serializing the request, response, and data.
    ///   - completionHandler:  The code to be executed once the request has finished.
    /// - Returns:              The request.
    @discardableResult
    public func response<Serializer: DataResponseSerializerProtocol>(
        queue: DispatchQueue? = nil,
        responseSerializer: Serializer,
        completionHandler: @escaping (DataResponse<Serializer.SerializedObject>) -> Void)
        -> Self
    {
        internalQueue.addOperation {
            self.serializationQueue.async {
                let start = CFAbsoluteTimeGetCurrent()
                let result = Result { try responseSerializer.serialize(request: self.request,
                                                                       response: self.response,
                                                                       data: self.data,
                                                                       error: self.error) }
                let end = CFAbsoluteTimeGetCurrent()

                let response = DataResponse(request: self.request,
                                            response: self.response,
                                            data: self.data,
                                            metrics: self.metrics,
                                            serializationDuration: (end - start),
                                            result: result)

                self.eventMonitor?.request(self, didParseResponse: response)

                (queue ?? .main).async { completionHandler(response) }
            }
        }

        return self
    }
}

extension DownloadRequest {
    /// Adds a handler to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:             The queue on which the completion handler is dispatched. Defaults to `nil`, which means
    ///                        the handler is called on `.main`.
    ///   - completionHandler: The code to be executed once the request has finished.
    /// - Returns:             The request.
    @discardableResult
    public func response(
        queue: DispatchQueue? = nil,
        completionHandler: @escaping (DownloadResponse<URL?>) -> Void)
        -> Self
    {
        internalQueue.addOperation {
            self.serializationQueue.async {
                let result = Result(value: self.fileURL , error: self.error)
                let response = DownloadResponse(request: self.request,
                                                response: self.response,
                                                fileURL: self.fileURL,
                                                resumeData: self.resumeData,
                                                metrics: self.metrics,
                                                serializationDuration: 0,
                                                result: result)

                (queue ?? .main).async { completionHandler(response) }
            }
        }

        return self
    }

    /// Adds a handler to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:              The queue on which the completion handler is dispatched. Defaults to `nil`, which means
    ///                         the handler is called on `.main`.
    ///   - responseSerializer: The response serializer responsible for serializing the request, response, and data
    ///                         contained in the destination url.
    ///   - completionHandler:  The code to be executed once the request has finished.
    /// - Returns:              The request.
    @discardableResult
    public func response<T: DownloadResponseSerializerProtocol>(
        queue: DispatchQueue? = nil,
        responseSerializer: T,
        completionHandler: @escaping (DownloadResponse<T.SerializedObject>) -> Void)
        -> Self
    {
        internalQueue.addOperation {
            self.serializationQueue.async {
                let start = CFAbsoluteTimeGetCurrent()
                let result = Result { try responseSerializer.serializeDownload(request: self.request,
                                                                               response: self.response,
                                                                               fileURL: self.fileURL,
                                                                               error: self.error) }
                let end = CFAbsoluteTimeGetCurrent()

                let response = DownloadResponse(request: self.request,
                                                response: self.response,
                                                fileURL: self.fileURL,
                                                resumeData: self.resumeData,
                                                metrics: self.metrics,
                                                serializationDuration: (end - start),
                                                result: result)

                (queue ?? .main).async { completionHandler(response) }
            }
        }

        return self
    }
}

// MARK: - Data

extension DataRequest {
    /// Adds a handler to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:             The queue on which the completion handler is dispatched. Defaults to `nil`, which means
    ///                        the handler is called on `.main`.
    ///   - completionHandler: The code to be executed once the request has finished.
    /// - Returns:             The request.
    @discardableResult
    public func responseData(
        queue: DispatchQueue? = nil,
        completionHandler: @escaping (DataResponse<Data>) -> Void)
        -> Self
    {
        return response(queue: queue,
                        responseSerializer: DataResponseSerializer(),
                        completionHandler: completionHandler)
    }
}

/// A `ResponseSerializer` that performs minimal reponse checking and returns any response data as-is. By default, a
/// request returning `nil` or no data is considered an error. However, if the response is has a status code valid for
/// empty responses (`204`, `205`), then an empty `Data` value is returned.
public final class DataResponseSerializer: ResponseSerializer {
    /// HTTP response codes for which empty responses are allowed.
    public let emptyResponseCodes: Set<Int>
    /// HTTP request methods for which empty responses are allowed.
    public let emptyRequestMethods: Set<HTTPMethod>

    /// Creates an instance using the provided values.
    ///
    /// - Parameters:
    ///   - emptyResponseCodes:  The HTTP response codes for which empty responses are allowed. Defaults to
    ///                          `[204, 205]`.
    ///   - emptyRequestMethods: The HTTP request methods for which empty responses are allowed. Defaults to `[.head]`.
    public init(emptyResponseCodes: Set<Int> = DataResponseSerializer.defaultEmptyResponseCodes,
                emptyRequestMethods: Set<HTTPMethod> = DataResponseSerializer.defaultEmptyRequestMethods) {
        self.emptyResponseCodes = emptyResponseCodes
        self.emptyRequestMethods = emptyRequestMethods
    }

    public func serialize(request: URLRequest?, response: HTTPURLResponse?, data: Data?, error: Error?) throws -> Data {
        guard error == nil else { throw error! }

        guard let data = data, !data.isEmpty else {
            guard emptyResponseAllowed(forRequest: request, response: response) else {
                throw AFError.responseSerializationFailed(reason: .inputDataNilOrZeroLength)
            }

            return Data()
        }

        return data
    }
}

extension DownloadRequest {
    /// Adds a handler to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:             The queue on which the completion handler is dispatched. Defaults to `nil`, which means
    ///                        the handler is called on `.main`.
    ///   - completionHandler: The code to be executed once the request has finished.
    /// - Returns:             The request.
    @discardableResult
    public func responseData(
        queue: DispatchQueue? = nil,
        completionHandler: @escaping (DownloadResponse<Data>) -> Void)
        -> Self
    {
        return response(
            queue: queue,
            responseSerializer: DataResponseSerializer(),
            completionHandler: completionHandler
        )
    }
}

// MARK: - String

/// A `ResponseSerializer` that decodes the response data as a `String`. By default, a request returning `nil` or no
/// data is considered an error. However, if the response is has a status code valid for empty responses (`204`, `205`),
/// then an empty `String` is returned.
public final class StringResponseSerializer: ResponseSerializer {
    /// Optional string encodeing used to validate the response.
    public let encoding: String.Encoding?
    /// HTTP response codes for which empty responses are allowed.
    public let emptyResponseCodes: Set<Int>
    /// HTTP request methods for which empty responses are allowed.
    public let emptyRequestMethods: Set<HTTPMethod>

    /// Creates an instance with the provided values.
    ///
    /// - Parameters:
    ///   - encoding:            A string encoding. Defaults to `nil`, in which case the encoding will be determined
    ///                          from the server response, falling back to the default HTTP character set, `ISO-8859-1`.
    ///   - emptyResponseCodes:  The HTTP response codes for which empty responses are allowed. Defaults to
    ///                          `[204, 205]`.
    ///   - emptyRequestMethods: The HTTP request methods for which empty responses are allowed. Defaults to `[.head]`.
    public init(encoding: String.Encoding? = nil,
                emptyResponseCodes: Set<Int> = StringResponseSerializer.defaultEmptyResponseCodes,
                emptyRequestMethods: Set<HTTPMethod> = StringResponseSerializer.defaultEmptyRequestMethods) {
        self.encoding = encoding
        self.emptyResponseCodes = emptyResponseCodes
        self.emptyRequestMethods = emptyRequestMethods
    }

    public func serialize(request: URLRequest?, response: HTTPURLResponse?, data: Data?, error: Error?) throws -> String {
        guard error == nil else { throw error! }

        guard let data = data, !data.isEmpty else {
            guard emptyResponseAllowed(forRequest: request, response: response) else {
                throw AFError.responseSerializationFailed(reason: .inputDataNilOrZeroLength)
            }

            return ""
        }

        var convertedEncoding = encoding

        if let encodingName = response?.textEncodingName as CFString?, convertedEncoding == nil {
            let ianaCharSet = CFStringConvertIANACharSetNameToEncoding(encodingName)
            let nsStringEncoding = CFStringConvertEncodingToNSStringEncoding(ianaCharSet)
            convertedEncoding = String.Encoding(rawValue: nsStringEncoding)
        }

        let actualEncoding = convertedEncoding ?? .isoLatin1

        guard let string = String(data: data, encoding: actualEncoding) else {
            throw AFError.responseSerializationFailed(reason: .stringSerializationFailed(encoding: actualEncoding))
        }

        return string
    }
}

extension DataRequest {
    /// Adds a handler to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:             The queue on which the completion handler is dispatched. Defaults to `nil`, which means
    ///                        the handler is called on `.main`.
    ///   - encoding:          The string encoding. Defaults to `nil`, in which case the encoding will be determined from
    ///                        the server response, falling back to the default HTTP character set, `ISO-8859-1`.
    ///   - completionHandler: A closure to be executed once the request has finished.
    /// - Returns:             The request.
    @discardableResult
    public func responseString(queue: DispatchQueue? = nil,
                               encoding: String.Encoding? = nil,
                               completionHandler: @escaping (DataResponse<String>) -> Void) -> Self {
        return response(queue: queue,
                        responseSerializer: StringResponseSerializer(encoding: encoding),
                        completionHandler: completionHandler)
    }
}

extension DownloadRequest {
    /// Adds a handler to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:             The queue on which the completion handler is dispatched. Defaults to `nil`, which means
    ///                        the handler is called on `.main`.
    ///   - encoding:          The string encoding. Defaults to `nil`, in which case the encoding will be determined from
    ///                        the server response, falling back to the default HTTP character set, `ISO-8859-1`.
    ///   - completionHandler: A closure to be executed once the request has finished.
    /// - Returns:             The request.
    @discardableResult
    public func responseString(
        queue: DispatchQueue? = nil,
        encoding: String.Encoding? = nil,
        completionHandler: @escaping (DownloadResponse<String>) -> Void)
        -> Self
    {
        return response(
            queue: queue,
            responseSerializer: StringResponseSerializer(encoding: encoding),
            completionHandler: completionHandler
        )
    }
}

// MARK: - JSON

/// A `ResponseSerializer` that decodes the response data using `JSONSerialization`. By default, a request returning
/// `nil` or no data is considered an error. However, if the response is has a status code valid for empty responses
/// (`204`, `205`), then an `NSNull`  value is returned.
public final class JSONResponseSerializer: ResponseSerializer {
    /// `JSONSerialization.ReadingOptions` used when serializing a response.
    public let options: JSONSerialization.ReadingOptions
    /// HTTP response codes for which empty responses are allowed.
    public let emptyResponseCodes: Set<Int>
    /// HTTP request methods for which empty responses are allowed.
    public let emptyRequestMethods: Set<HTTPMethod>

    /// Creates an instance with the provided values.
    ///
    /// - Parameters:
    ///   - options:             The options to use. Defaults to `.allowFragments`.
    ///   - emptyResponseCodes:  The HTTP response codes for which empty responses are allowed. Defaults to
    ///                          `[204, 205]`.
    ///   - emptyRequestMethods: The HTTP request methods for which empty responses are allowed. Defaults to `[.head]`.
    public init(options: JSONSerialization.ReadingOptions = .allowFragments,
                emptyResponseCodes: Set<Int> = JSONResponseSerializer.defaultEmptyResponseCodes,
                emptyRequestMethods: Set<HTTPMethod> = JSONResponseSerializer.defaultEmptyRequestMethods) {
        self.options = options
        self.emptyResponseCodes = emptyResponseCodes
        self.emptyRequestMethods = emptyRequestMethods
    }

    public func serialize(request: URLRequest?, response: HTTPURLResponse?, data: Data?, error: Error?) throws -> Any {
        guard error == nil else { throw error! }

        guard let data = data, !data.isEmpty else {
            guard emptyResponseAllowed(forRequest: request, response: response) else {
                throw AFError.responseSerializationFailed(reason: .inputDataNilOrZeroLength)
            }

            return NSNull()
        }

        do {
            return try JSONSerialization.jsonObject(with: data, options: options)
        } catch {
            throw AFError.responseSerializationFailed(reason: .jsonSerializationFailed(error: error))
        }
    }
}

extension DataRequest {
    /// Adds a handler to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:             The queue on which the completion handler is dispatched. Defaults to `nil`, which means
    ///                        the handler is called on `.main`.
    ///   - options:           The JSON serialization reading options. Defaults to `.allowFragments`.
    ///   - completionHandler: A closure to be executed once the request has finished.
    /// - Returns:             The request.
    @discardableResult
    public func responseJSON(queue: DispatchQueue? = nil,
                             options: JSONSerialization.ReadingOptions = .allowFragments,
                             completionHandler: @escaping (DataResponse<Any>) -> Void) -> Self {
        return response(queue: queue,
                        responseSerializer: JSONResponseSerializer(options: options),
                        completionHandler: completionHandler)
    }
}

extension DownloadRequest {
    /// Adds a handler to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:             The queue on which the completion handler is dispatched. Defaults to `nil`, which means
    ///                        the handler is called on `.main`.
    ///   - options:           The JSON serialization reading options. Defaults to `.allowFragments`.
    ///   - completionHandler: A closure to be executed once the request has finished.
    /// - Returns:             The request.
    @discardableResult
    public func responseJSON(
        queue: DispatchQueue? = nil,
        options: JSONSerialization.ReadingOptions = .allowFragments,
        completionHandler: @escaping (DownloadResponse<Any>) -> Void)
        -> Self
    {
        return response(queue: queue,
                        responseSerializer: JSONResponseSerializer(options: options),
                        completionHandler: completionHandler)
    }
}

// MARK: - Empty

/// A type representing an empty response. Use `Empty.value` to get the instance.
public struct Empty: Decodable {
    public static let value = Empty()
}

// MARK: - JSON Decodable

/// A `ResponseSerializer` that decodes the response data as a generic value using a `JSONDecoder`. By default, a
/// request returning `nil` or no data is considered an error. However, if the response is has a status code valid for
/// empty responses (`204`, `205`), then the `Empty.value` value is returned.
public final class JSONDecodableResponseSerializer<T: Decodable>: ResponseSerializer {
    /// The `JSONDecoder` instance used to decode responses.
    public let decoder: JSONDecoder
    /// HTTP response codes for which empty responses are allowed.
    public let emptyResponseCodes: Set<Int>
    /// HTTP request methods for which empty responses are allowed.
    public let emptyRequestMethods: Set<HTTPMethod>

    /// Creates an instance using the values provided.
    ///
    /// - Parameters:
    ///   - decoder:           The `JSONDecoder`. Defaults to a `JSONDecoder()`.
    ///   - emptyResponseCodes:  The HTTP response codes for which empty responses are allowed. Defaults to
    ///                          `[204, 205]`.
    ///   - emptyRequestMethods: The HTTP request methods for which empty responses are allowed. Defaults to `[.head]`.
    public init(decoder: JSONDecoder = JSONDecoder(),
                emptyResponseCodes: Set<Int> = JSONDecodableResponseSerializer.defaultEmptyResponseCodes,
                emptyRequestMethods: Set<HTTPMethod> = JSONDecodableResponseSerializer.defaultEmptyRequestMethods) {
        self.decoder = decoder
        self.emptyResponseCodes = emptyResponseCodes
        self.emptyRequestMethods = emptyRequestMethods
    }

    public func serialize(request: URLRequest?, response: HTTPURLResponse?, data: Data?, error: Error?) throws -> T {
        guard error == nil else { throw error! }

        guard let data = data, !data.isEmpty else {
            guard emptyResponseAllowed(forRequest: request, response: response) else {
                throw AFError.responseSerializationFailed(reason: .inputDataNilOrZeroLength)
            }

            guard let emptyValue = Empty.value as? T else {
                throw AFError.responseSerializationFailed(reason: .invalidEmptyResponse(type: "\(T.self)"))
            }

            return emptyValue
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AFError.responseSerializationFailed(reason: .jsonDecodingFailed(error: error))
        }
    }
}

extension DataRequest {
    /// Adds a handler to be called once the request has finished.
    ///
    /// - Parameters:
    ///   - queue:             The queue on which the completion handler is dispatched. Defaults to `nil`, which means
    ///                        the handler is called on `.main`.
    ///   - decoder:           The decoder to use to decode the response. Defaults to a `JSONDecoder` with default
    ///                        settings.
    ///   - completionHandler: A closure to be executed once the request has finished.
    /// - Returns:             The request.
    @discardableResult
    public func responseJSONDecodable<T: Decodable>(queue: DispatchQueue? = nil,
                                                    decoder: JSONDecoder = JSONDecoder(),
                                                    completionHandler: @escaping (DataResponse<T>) -> Void) -> Self {
        return response(queue: queue,
                        responseSerializer: JSONDecodableResponseSerializer(decoder: decoder),
                        completionHandler: completionHandler)
    }
}
