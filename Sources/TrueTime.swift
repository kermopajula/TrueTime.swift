//
//  TrueTime.swift
//  TrueTime
//
//  Created by Michael Sanders on 7/9/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import CTrueTime
import Foundation
import Result

@objc public enum TrueTimeError: Int {
    case cannotFindHost
    case dnsLookupFailed
    case timedOut
    case offline
    case badServerResponse
    case noValidPacket
}

@objc(NTPReferenceTime)
public final class ReferenceTime: NSObject {
    @objc public var uptimeInterval: TimeInterval { return underlyingValue.uptimeInterval }
    @objc public var time: Date { return underlyingValue.time }
    @objc public var uptime: timeval { return underlyingValue.uptime }
    @objc public func now() -> Date {
        let now = underlyingValue.now()
        UserDefaultUtil.instance.save(date: underlyingValue.time, uptime: uptime)
        
        return now
    }
    
    public convenience init(time: Date, uptime: timeval) {
        self.init(FrozenReferenceTime(time: time, uptime: uptime))
    }
    
    init(_ underlyingValue: FrozenTime) {
        self.underlyingValueLock = GCDLock(value: underlyingValue)
    }
    
    public override var description: String {
        return "\(type(of: self))(underlyingValue: \(underlyingValue)"
    }
    
    private let underlyingValueLock: GCDLock<FrozenTime>
    var underlyingValue: FrozenTime {
        get { return underlyingValueLock.read() }
        set { underlyingValueLock.write(newValue) }
    }
}

public typealias ReferenceTimeResult = Result<ReferenceTime, NSError>
public typealias ReferenceTimeCallback = (ReferenceTimeResult) -> Void
public typealias LogCallback = (String) -> Void

@objc public final class TrueTimeClient: NSObject {
    @objc public static let sharedInstance = TrueTimeClient()
    @objc required public init(timeout: TimeInterval = 8,
                               maxRetries: Int = 3,
                               maxConnections: Int = 5,
                               maxServers: Int = 5,
                               numberOfSamples: Int = 4,
                               pollInterval: TimeInterval = 512) {
        config = NTPConfig(timeout: timeout,
                           maxRetries: maxRetries,
                           maxConnections: maxConnections,
                           maxServers: maxServers,
                           numberOfSamples: numberOfSamples,
                           pollInterval: pollInterval)
        ntp = NTPClient(config: config)
    }
    
    @objc public func start(pool: [String] = ["time.apple.com"], port: Int = 123) {
        ntp.start(pool: pool, port: port)
    }
    
    @objc public func pause() {
        ntp.pause()
    }
    
    public func fetchIfNeeded(queue callbackQueue: DispatchQueue = .main,
                              first: ReferenceTimeCallback? = nil,
                              completion: ReferenceTimeCallback? = nil) {
        ntp.fetchIfNeeded(queue: callbackQueue, first: first, completion: completion)
    }
    
    #if DEBUG_LOGGING
    @objc public var logCallback: LogCallback? = defaultLogger {
        didSet {
            ntp.logger = logCallback
        }
    }
    #endif
    
    @objc public var referenceTime: ReferenceTime? {
        return fetchReferenceTime()
        
    }
    @objc public var timeout: TimeInterval { return config.timeout }
    @objc public var maxRetries: Int { return config.maxRetries }
    @objc public var maxConnections: Int { return config.maxConnections }
    @objc public var maxServers: Int { return config.maxServers}
    @objc public var numberOfSamples: Int { return config.numberOfSamples}
    
    private let config: NTPConfig
    private let ntp: NTPClient
}

extension TrueTimeClient {
    @objc public func fetchFirstIfNeeded(success: @escaping (ReferenceTime) -> Void, failure: ((NSError) -> Void)?) {
        fetchFirstIfNeeded(success: success, failure: failure, onQueue: .main)
    }
    
    @objc public func fetchIfNeeded(success: @escaping (ReferenceTime) -> Void, failure: ((NSError) -> Void)?) {
        fetchIfNeeded(success: success, failure: failure, onQueue: .main)
    }
    
    @objc public func fetchFirstIfNeeded(success: @escaping (ReferenceTime) -> Void,
                                         failure: ((NSError) -> Void)?,
                                         onQueue queue: DispatchQueue) {
        fetchIfNeeded(queue: queue, first: { result in
            self.mapBridgedResult(result, success: success, failure: failure)
        })
    }
    
    @objc public func fetchIfNeeded(success: @escaping (ReferenceTime) -> Void,
                                    failure: ((NSError) -> Void)?,
                                    onQueue queue: DispatchQueue) {
        fetchIfNeeded(queue: queue) { result in
            self.mapBridgedResult(result, success: success, failure: failure)
        }
    }
    
    private func mapBridgedResult(_ result: ReferenceTimeResult,
                                  success: (ReferenceTime) -> Void,
                                  failure: ((NSError) -> Void)?) {
        result.analysis(ifSuccess: success, ifFailure: { err in failure?(err) })
    }
    
    fileprivate func fetchReferenceTime() -> ReferenceTime? {
        var referenceTime: ReferenceTime?
        
        if let reference = ntp.referenceTime {
            referenceTime = reference
        }
        else {
            let userDefaults    = UserDefaultUtil.instance
            let (date, uptime)  = userDefaults.loadSavedDate()

            if let uptime = uptime {
                if uptime.milliseconds > timeval.uptime().milliseconds {
                    userDefaults.clearValues()
                }
                else {
                    referenceTime = ReferenceTime(time: date, uptime: uptime)
                }
            }
        }
        
        return referenceTime
    }
}

let defaultLogger: LogCallback = { print($0) }


class UserDefaultUtil {
    
    let userDefaults        = UserDefaults.standard
    let dateValue           = "dateValue"
    let secUptime           = "secUptime"
    let milisecUptime       = "milisecUptime"
    
    private init() {}
    private static var _instance: UserDefaultUtil?
    
    static var instance: UserDefaultUtil {
        if _instance == nil { _instance = UserDefaultUtil() }
        return _instance!
    }
    
    
    func save(date: Date, uptime: timeval) {
        userDefaults.set(date.timeIntervalSince1970 as Double, forKey: dateValue)
        userDefaults.set(uptime.tv_sec, forKey: secUptime)
        userDefaults.set(uptime.tv_usec, forKey: milisecUptime)
    }
    
    func clearValues() {
        userDefaults.set(nil, forKey: dateValue)
        userDefaults.set(nil, forKey: secUptime)
        userDefaults.set(nil, forKey: milisecUptime)
    }
    
    func loadSavedDate() -> (Date, timeval?) {
        let timeInterval    = userDefaults.double(forKey: dateValue)
        let date            = Date(timeIntervalSince1970: timeInterval)
        
        let secTimeValue        = userDefaults.value(forKey: secUptime) as? Int
        let milisecTimeValue    = userDefaults.value(forKey: milisecUptime) as? Int32
        
        
        var timeValue: timeval?
        if let sec = secTimeValue, let milisec = milisecTimeValue {
            timeValue   = timeval(tv_sec: sec, tv_usec: milisec)
        }
        
        return (date, timeValue)
    }
    
    
}

extension Date {
    
    mutating func add(_ value: Int, to component: Calendar.Component) {
        if let date = Calendar.current.date(byAdding: component, value: value, to: self) {
            self = date
        }
    }
    
}
