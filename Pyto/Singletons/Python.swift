
//
//  Python.swift
//  Pyto
//
//  Created by Adrian Labbe on 9/8/18.
//  Copyright © 2018 Adrian Labbé. All rights reserved.
//

import Foundation
import AVFoundation
#if MAIN
import UIKit
#elseif os(iOS) && !WIDGET
@_silgen_name("PyRun_SimpleStringFlags")
func PyRun_SimpleStringFlags(_: UnsafePointer<Int8>!, _: UnsafeMutablePointer<Any>!)

@_silgen_name("Py_DecodeLocale")
func Py_DecodeLocale(_: UnsafePointer<Int8>!, _: UnsafeMutablePointer<Int>!) -> UnsafeMutablePointer<wchar_t>
#endif

/// A class for interacting with `Cpython`
@objc public class Python: NSObject {
    
    #if !MAIN
    /// Throws a fatal error.
    ///
    /// - Parameters:
    ///     - message: Message describing error.
    @objc func fatalError(_ message: String) -> Never {
        return Swift.fatalError(message)
    }
    #else
    /// The full  Python version
    @objc public var version: String {
        return String(cString: Py_GetVersion())
    }
    #endif
    
    /// The shared and unique instance
    @objc public static let shared = Python()
    
    private override init() {}
    
    /// The bundle containing all Python resources.
    @objc var bundle: Bundle {
        if Bundle.main.bundleIdentifier?.hasSuffix(".ada.Pyto") == true || Bundle.main.bundleIdentifier?.hasSuffix(".ada.Pyto.Pyto-Widget") == true {
            return Bundle(identifier: "ch.ada.Python")!
        } else if let bundle = Bundle(path: Bundle.main.path(forResource: "Python.framework", ofType: nil) ?? "") {
            return bundle
        } else if let bundle = Bundle(path: ((Bundle.main.privateFrameworksPath ?? "") as NSString).appendingPathComponent("Python.framework")) {
            return bundle
        } else {
            return Bundle(for: Python.self)
        }
    }
    
    /// The queue running scripts.
    @objc public let queue = DispatchQueue.global(qos: .userInteractive)
        
    /// Additional builtin modules names.
    @objc public var modules = NSMutableArray()
    
    /// Imported builtin modules.
    @objc public var importedModules = NSMutableArray()
    
    /// If set to `true`, scripts will run inside the REPL.
    @objc public var isREPLRunning = false
    
    /// Set to `true` while the REPL is asking for input.
    @objc public var isREPLAskingForInput = false
    
    /// The thread running current thread.
    @objc var currentRunningThreadID = -1
    
    /// All the Python output.
    public var output = ""
    
    /// The last error's type.
    @objc public var errorType: String?
    
    /// The last error's reason.
    @objc public var errorReason: String?
    
    /// The arguments to pass to scripts.
    @objc public var args = NSMutableArray()

    /// A boolean indicating whether the app is running out of memory.
    @objc public var tooMuchUsedMemory = false
    
    /// A class representing a script to run.
    @objc public class Script: NSObject {
        
        /// The path of the script.
        @objc public var path: String
        
        /// Set to `true` if the script should  be debugged with `pdb`.
        @objc public var debug: Bool
        
        @objc public var breakpoints: NSArray
        
        /// Initializes the script.
        ///
        /// - Parameters:
        ///     - path: The path of the script.
        ///     - debug: Set to `true` if the script should  be debugged with `pdb`.
        ///     - breakpoints: Line numbers where breakpoints should be placed if the script should be debugged.
        @objc public init(path: String, debug: Bool, breakpoints: [Int] = []) {
            self.path = path
            self.debug = debug
            self.breakpoints = NSArray(array: breakpoints)
        }
    }
    
    /// A script to be executed from the Watch app.
    @objc public class WatchScript: Script {
     
        /// The URL where the script is stored.
        public static let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Watch.py")
        
        /// Initilializes the script with given code.
        ///
        /// - Parameters:
        ///     - code: The code to run.
        init(code: String) {
            let url = WatchScript.scriptURL
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
            try? code.write(to: url, atomically: true, encoding: .utf8)
            
            super.init(path: url.path, debug: false)
        }
    }
    
    /// Python code to run.
    @objc public var codeToRun: String?
    
    /// Runs given code.
    ///
    /// - Parameters:
    ///     - code: Python code to run.
    @objc public func run(code: String) {
        codeToRun = code
    }
    
    /// The path of the script to run. Set it to run it.
    @objc public var scriptToRun: Script?
    
    @objc private func removeScriptFromList(_ script: String) {
        sleep(1)
        while runningScripts.index(of: script) != NSNotFound {
            let arr = NSMutableArray(array: runningScripts)
            arr.removeObjects(at: IndexSet(integer: runningScripts.index(of: script)))
            runningScripts = arr
        }
    }
    
    @objc private func addScriptToList(_ script: String) {
        if runningScripts.index(of: script) == NSNotFound {
            let arr = NSMutableArray(array: runningScripts)
            arr.add(script)
            runningScripts = arr
        }
    }
    
    /// The path of the scripts running.
    @objc public var runningScripts = NSArray() {
        didSet {
            DispatchQueue.main.async {
                #if MAIN
                
                #if WIDGET
                let visibles = [ConsoleViewController.visible ?? ConsoleViewController()]
                #else
                let visibles = ConsoleViewController.visibles
                #endif
                
                for contentVC in visibles {
                    guard let editor = contentVC.editorSplitViewController?.editor, let scriptPath = editor.document?.fileURL.path else {
                        return
                    }
                    
                    guard !(contentVC.editorSplitViewController is REPLViewController) && !(contentVC.editorSplitViewController is RunModuleViewController) && !(contentVC.editorSplitViewController is PipInstallerViewController) else {
                        let installer = contentVC.editorSplitViewController as? PipInstallerViewController
                        installer?.done = !(self.runningScripts.contains(scriptPath))
                        installer?.navigationItem.leftBarButtonItem?.isEnabled = installer?.done ?? false
                        return
                    }
                    
                    let item = editor.parent?.navigationItem
                    
                    if item?.rightBarButtonItem != contentVC.editorSplitViewController?.closeConsoleBarButtonItem {
                        if self.runningScripts.contains(scriptPath) {
                            item?.rightBarButtonItem = editor.stopBarButtonItem
                        } else {
                            item?.rightBarButtonItem = editor.runBarButtonItem
                            
                            if contentVC.editorSplitViewController?.editor.textView.text == PyCallbackHelper.code {
                                // Run callback
                                
                                if PyCallbackHelper.cancelled, let cancel = PyCallbackHelper.cancelURL, let url = URL(string: cancel) {
                                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                                } else if let msg = PyCallbackHelper.exception, let error = PyCallbackHelper.errorURL, let url = URL(string: error)?.appendingParameters(params: ["errorMessage": msg]) {
                                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                                } else if let success = PyCallbackHelper.successURL, let url = URL(string: success)?.appendingParameters(params: ["result":contentVC.textView.text]) {
                                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                                }
                                
                                PyCallbackHelper.cancelURL = nil
                                PyCallbackHelper.errorURL = nil
                                PyCallbackHelper.successURL = nil
                                PyCallbackHelper.cancelled = false
                                PyCallbackHelper.exception = nil
                            }
                        }
                    }
                }
                #endif
            }
        }
    }
    
    /// Add a script here to send `KeyboardInterrupt`to it.
    @objc public var scriptsToInterrupt = NSMutableArray()
    
    /// Add a script here to send `SystemExit`to it.
    @objc public var scriptsToExit = NSMutableArray()
    
    private var _cwd = FileManager.default.urls(for: .documentDirectory, in: .allDomainsMask)[0].path
    
    /// The directory from which the script is executed.
    @objc public var currentWorkingDirectory: String {
        get {
            var cwd = ""
            let semaphore = DispatchSemaphore(value: 0)
            queue.async {
                cwd = self._cwd
                semaphore.signal()
            }
                semaphore.wait()
            return cwd
        }
        
        set {
            queue.async {
                self._cwd = newValue
            }
        }
    }
    
    /// Returns the environment.
    @objc var environment: NSDictionary {
        return ProcessInfo.processInfo.environment as NSDictionary
    }
    
    /// Set to `true` when the REPL is ready to run scripts.
    @objc var isSetup = false
    
    /// Exposes Pyto modules to Pyhon.
    @available(*, deprecated, message: "The Library is now located on app bundle.")
    @objc public func importPytoLib() {
        guard let newLibURL = FileManager.default.urls(for: .libraryDirectory, in: .allDomainsMask).first?.appendingPathComponent("pylib") else {
            fatalError("WHY IS THAT HAPPENING????!!!!!!! HOW THE LIBRARY DIR CANNOT BE FOUND!!!!???")
        }
        if FileManager.default.fileExists(atPath: newLibURL.path) {
            try? FileManager.default.removeItem(at: newLibURL)
        }
    }
    
    /// The thread running script.
    @objc public var thread: Thread?
    
    /// Runs the given script.
    ///
    /// - Parameters:
    ///     - script: Script to run.
    public func run(script: Script) {
        scriptToRun = script
    }
    
    /// Run script at given URL. Will be ran with Python C API directly. Call it once!
    ///
    /// - Parameters:
    ///     - url: URL of the Python script to run.
    @objc public func runScript(at url: URL) {
        queue.async {
            
            self.thread = Thread.current
            
            guard !self.isREPLRunning else {
                PyOutputHelper.print(Localizable.Python.alreadyRunning, script: nil) // Should not be called. When the REPL is running, run the script inside it.
                return
            }
            
            self.isREPLRunning = true
            
            #if WIDGET
            let arr = NSMutableArray(array: self.runningScripts)
            arr.add(url.path)
            self.runningScripts = arr
            PyRun_SimpleFileExFlags(fopen(url.path.cValue, "r"), url.lastPathComponent.cValue, 0, nil)
            #else
            guard let startupURL = Bundle(for: Python.self).url(forResource: "Startup", withExtension: "py"), let src = try? String(contentsOf: startupURL) else {
                PyOutputHelper.print(Localizable.Python.alreadyRunning, script: nil)
                return
            }
            
            let code = String(format: src, url.path)
            PyRun_SimpleStringFlags(code.cValue, nil)
            #endif
        }
    }

    /// Sends `SystemExit`.
    ///
    /// - Parameters:
    ///     - script: The path of the script to stop.
    @objc public func stop(script: String) {
        if scriptsToExit.index(of: script) == NSNotFound {
            scriptsToExit.add(script)
        }
    }
    
    /// Sends `KeyboardInterrupt`.
    ///
    /// - Parameters:
    ///     - script: The path of the script to interrupt.
    @objc public func interrupt(script: String) {
        if scriptsToInterrupt.index(of: script) == NSNotFound {
            scriptsToInterrupt.add(script)
        }
    }

    /// Checks if a script is currently running.
    ///
    /// - Parameters:
    ///     - script: Script to check.
    ///
    /// - Returns: `true` if the passed script is currently running.
    @objc public func isScriptRunning(_ script: String) -> Bool {
        return runningScripts.contains(script)
    }
}

