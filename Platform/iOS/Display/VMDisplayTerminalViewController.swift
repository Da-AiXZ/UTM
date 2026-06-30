//
// Copyright © 2022 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation
import SwiftTerm
import SwiftUI
import WebKit

@objc class VMDisplayTerminalViewController: VMDisplayViewController {
    private var terminalView: TerminalView!
    var vmSerialPort: CSPort {
        willSet {
            vmSerialPort.delegate = nil
            newValue.delegate = self
            terminalView.getTerminal().resetToInitialState()
            terminalView.getTerminal().softReset()
        }
    }
    
    private var style: UTMConfigurationTerminal?
    private var keyboardDelta: CGFloat = 0
    
    required init(port: CSPort, style: UTMConfigurationTerminal? = nil) {
        self.vmSerialPort = port
        super.init(nibName: nil, bundle: nil)
        port.delegate = self
        self.style = style
    }
    
    required init?(coder: NSCoder) {
        return nil
    }
    
    override func loadView() {
        super.loadView()
        terminalView = TerminalView(frame: makeFrame (keyboardDelta: 0))
        terminalView.terminalDelegate = self
        view.insertSubview(terminalView, at: 0)
        styleTerminal()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setupKeyboardMonitor()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cleanupKeyboardMonitor()
    }
    
    override func enterLive() {
        super.enterLive()
        DispatchQueue.main.async {
            let terminalSize = CGSize(width: self.terminalView.getTerminal().cols, height: self.terminalView.getTerminal().rows)
            self.delegate.displayViewSize = terminalSize
        }
    }
    
    override func showKeyboard() {
        super.showKeyboard()
        _ = terminalView.becomeFirstResponder()
    }
    
    override func hideKeyboard() {
        super.hideKeyboard()
        _ = terminalView.resignFirstResponder()
    }
}

// MARK: - Layout terminal
extension VMDisplayTerminalViewController {
    var useAutoLayout: Bool {
        get { true }
    }

    // This prevents curved edge from cutting off the content
    var additionalTopPadding: CGFloat {
        if UIDevice.current.userInterfaceIdiom == .pad {
            let scenes = UIApplication.shared.connectedScenes
            let windowScene = scenes.first as? UIWindowScene
            guard let window = windowScene?.windows.first else { return 0 }
            return window.safeAreaInsets.bottom
        } else {
            return 0
        }
    }

    func makeFrame (keyboardDelta: CGFloat, _ fn: String = #function, _ ln: Int = #line) -> CGRect
    {
        if useAutoLayout {
            return CGRect.zero
        } else {
            return CGRect (x: view.safeAreaInsets.left,
                           y: view.safeAreaInsets.top + additionalTopPadding,
                           width: view.frame.width - view.safeAreaInsets.left - view.safeAreaInsets.right,
                           height: view.frame.height - view.safeAreaInsets.top - keyboardDelta)
        }
    }
    
    func setupKeyboardMonitor ()
    {
        if #available(iOS 15.0, *), useAutoLayout {
            #if os(visionOS)
            let inputAccessoryHeight: CGFloat = 0
            #else
            let inputAccessoryHeight = terminalView.inputAccessoryView?.frame.height ?? 0
            #endif
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: additionalTopPadding).isActive = true
            terminalView.leftAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leftAnchor).isActive = true
            terminalView.rightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.rightAnchor).isActive = true
            terminalView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -inputAccessoryHeight).isActive = true
        } else {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardWillShow),
                name: UIWindow.keyboardWillShowNotification,
                object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardWillHide),
                name: UIWindow.keyboardWillHideNotification,
                object: nil)
        }
    }
    
    func cleanupKeyboardMonitor() {
        if #unavailable(iOS 15) {
            NotificationCenter.default.removeObserver(self, name: UIWindow.keyboardWillShowNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: UIWindow.keyboardWillHideNotification, object: nil)
        }
    }
    
    @objc private func keyboardWillShow(_ notification: NSNotification) {
        guard let keyboardValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        
        let keyboardScreenEndFrame = keyboardValue.cgRectValue
        let keyboardViewEndFrame = view.convert(keyboardScreenEndFrame, from: view.window)
        keyboardDelta = keyboardViewEndFrame.height
        terminalView.frame = makeFrame(keyboardDelta: keyboardViewEndFrame.height)
    }
    
    @objc private func keyboardWillHide(_ notification: NSNotification) {
        //let key = UIResponder.keyboardFrameBeginUserInfoKey
        keyboardDelta = 0
        terminalView.frame = makeFrame(keyboardDelta: 0)
    }
}

// MARK: - Style terminal
extension VMDisplayTerminalViewController {
    private func styleTerminal() {
        guard let style = style else {
            return
        }
        let fontSize = style.fontSize
        let fontName = style.font.rawValue
        if fontName != "" {
            let orig = terminalView.font
            let new = UIFont(name: fontName, size: CGFloat(fontSize)) ?? orig
            terminalView.font = new
        } else {
            let orig = terminalView.font
            let new = UIFont(descriptor: orig.fontDescriptor, size: CGFloat(fontSize))
            terminalView.font = new
        }
        if let consoleTextColor = style.foregroundColor,
           let textColor = Color(hexString: consoleTextColor),
           let consoleBackgroundColor = style.backgroundColor,
           let backgroundColor = Color(hexString: consoleBackgroundColor) {
            terminalView.nativeForegroundColor = UIColor(textColor)
            terminalView.nativeBackgroundColor = UIColor(backgroundColor)
        }
        terminalView.getTerminal().setCursorStyle(style.hasCursorBlink ? .blinkBlock : .steadyBlock)
        terminalView.optionAsMetaKey = boolForSetting("OptionAsMetaKey")
    }
}

// MARK: - TerminalViewDelegate
extension VMDisplayTerminalViewController: TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        delegate?.displayViewSize = CGSize(width: newCols, height: newRows)
    }
    
    func setTerminalTitle(source: TerminalView, title: String) {
    }
    
    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
    }
    
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
    }
    
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        delegate?.displayDidAssertUserInteraction()
        vmSerialPort.write(Data(data))
    }
    
    func scrolled(source: TerminalView, position: Double) {
        delegate?.displayDidAssertUserInteraction()
    }
    
    func bell(source: TerminalView) {
    }
    
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
    }
    
    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(bytes: content, encoding: .utf8) {
            UIPasteboard.general.string = str
        }
    }
}

// MARK: - CSPortDelegate
extension VMDisplayTerminalViewController: CSPortDelegate {
    func portDidDisconect(_ port: CSPort) {
    }
    
    func port(_ port: CSPort, didError error: String) {
        delegate?.serialDidError(error)
    }
    
    func port(_ port: CSPort, didRecieveData data: Data) {
        if let terminalView = terminalView {
            let arr = [UInt8](data)[...]
            DispatchQueue.main.async {
                terminalView.feed(byteArray: arr)
            }
        }
    }
}

// MARK: - xterm.js based terminal (better CJK + touch support)

@objc class VMDisplayWebTerminalViewController: VMDisplayViewController {
    
    private var webView: WKWebView!
    private var isTerminalReady = false
    private var pendingData: [Data] = []
    
    var vmSerialPort: CSPort {
        willSet {
            vmSerialPort.delegate = nil
            newValue.delegate = self
            if isTerminalReady {
                webView?.evaluateJavaScript("clearTerminal();", completionHandler: nil)
            }
        }
    }
    
    private var style: UTMConfigurationTerminal?
    
    required init(port: CSPort, style: UTMConfigurationTerminal? = nil) {
        self.vmSerialPort = port
        super.init(nibName: nil, bundle: nil)
        port.delegate = self
        self.style = style
    }
    
    required init?(coder: NSCoder) {
        return nil
    }
    
    override func loadView() {
        super.loadView()
        
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        
        let contentController = config.userContentController
        contentController.add(self, name: "terminalInput")
        contentController.add(self, name: "terminalResize")
        contentController.add(self, name: "terminalReady")
        contentController.add(self, name: "terminalSelection")
        
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 1)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(webView, at: 0)
        
        webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor).isActive = true
        webView.leftAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leftAnchor).isActive = true
        webView.rightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.rightAnchor).isActive = true
        
        if #available(iOS 15.0, *) {
            webView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor).isActive = true
        } else {
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        }
        
        loadTerminalHTML()
    }
    
    override func enterLive() {
        super.enterLive()
    }
    
    override func showKeyboard() {
        super.showKeyboard()
        if isTerminalReady {
            webView?.evaluateJavaScript("focusTerminal();", completionHandler: nil)
        }
    }
    
    override func hideKeyboard() {
        super.hideKeyboard()
        webView?.endEditing(true)
    }
    
    private func loadTerminalHTML() {
        if let htmlURL = Bundle.main.url(forResource: "terminal", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        } else {
            NSLog("[ClaudeBox] terminal.html not found in bundle!")
        }
    }
    
    private func applyStyle() {
        guard let style = style else { return }
        let fontSize = style.fontSize
        webView?.evaluateJavaScript("setFontSize(\(fontSize));", completionHandler: nil)
        
        var theme: [String: Any] = [:]
        if let bg = style.backgroundColor {
            theme["background"] = bg
        }
        if let fg = style.foregroundColor {
            theme["foreground"] = fg
        }
        if !theme.isEmpty {
            if let jsonData = try? JSONSerialization.data(withJSONObject: theme),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                webView?.evaluateJavaScript("setTheme(\(jsonString));", completionHandler: nil)
            }
        }
    }
}

extension VMDisplayWebTerminalViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "terminalReady":
            isTerminalReady = true
            applyStyle()
            for data in pendingData {
                feedToTerminal(data)
            }
            pendingData.removeAll()
            if let body = message.body as? [String: Any],
               let cols = body["cols"] as? Int,
               let rows = body["rows"] as? Int {
                delegate?.displayViewSize = CGSize(width: cols, height: rows)
            }
            
        case "terminalInput":
            if let input = message.body as? String {
                let data = Data(input.utf8)
                vmSerialPort.write(data)
                delegate?.displayDidAssertUserInteraction()
            }
            
        case "terminalResize":
            if let body = message.body as? [String: Any],
               let cols = body["cols"] as? Int,
               let rows = body["rows"] as? Int {
                delegate?.displayViewSize = CGSize(width: cols, height: rows)
            }
            
        case "terminalSelection":
            if let selection = message.body as? String {
                UIPasteboard.general.string = selection
            }
            
        default:
            break
        }
    }
}

extension VMDisplayWebTerminalViewController: CSPortDelegate {
    func portDidDisconect(_ port: CSPort) {
    }
    
    func port(_ port: CSPort, didError error: String) {
        delegate?.serialDidError(error)
    }
    
    func port(_ port: CSPort, didRecieveData data: Data) {
        DispatchQueue.main.async {
            if self.isTerminalReady {
                self.feedToTerminal(data)
            } else {
                self.pendingData.append(data)
            }
        }
    }
    
    private func feedToTerminal(_ data: Data) {
        let base64 = data.base64EncodedString()
        webView?.evaluateJavaScript("writeToTerminal('\(base64)');", completionHandler: nil)
    }
}
