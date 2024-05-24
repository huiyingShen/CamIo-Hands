//
//  ViewController.swift
//  CamIoAgain
//
//  Created by Huiying Shen on 2/14/19.
//  Copyright © 2019 Huiying Shen. All rights reserved.
//

import UIKit
import AVFoundation
import Vision
import Speech
import MediaPipeTasksVision

// MARK: - Protocols

protocol InferenceResultDeliveryDelegate: AnyObject {
    func didPerformInference(result: ResultBundle?)
}

public protocol AudioManagerDelegate: NSObjectProtocol {
    func speaked()
}

// MARK: - ButtonLabelViewController

class ButtonLabelViewController: UIViewController {
    let camIoWrapper = CamIoWrapper()
    var buttons = [UIButton]()
    var labels = [UILabel]()
    
    func addButton(x: Int, y: Int, w: Int, h: Int, title: String, color: UIColor, selector: Selector) -> UIButton {
        let btn = UIButton()
        btn.frame = CGRect(x: x, y: y, width: w, height: h)
        btn.setTitle(title, for: .normal)
        btn.setTitleColor(color, for: .normal)
        btn.backgroundColor = .lightGray
        btn.addTarget(self, action: selector, for: .touchUpInside)
        view.addSubview(btn)
        buttons.append(btn)
        return btn
    }
    
    func addLabel(x: Int, y: Int, w: Int, h: Int, text: String, color: UIColor) -> UILabel {
        let label = UILabel()
        label.frame = CGRect(x: x, y: y, width: w, height: h)
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.textColor = color
        label.backgroundColor = .lightGray
        label.text = text
        view.addSubview(label)
        labels.append(label)
        return label
    }
}

// MARK: - ViewController

class ViewController: ButtonLabelViewController, AudioManagerDelegate {
    
    // MARK: Properties
    
    private var _handLandmarkerService: HandLandmarkerService?
    private var handLandmarkerService: HandLandmarkerService? {
        get {
            handLandmarkerServiceQueue.sync {
                return _handLandmarkerService
            }
        }
        set {
            handLandmarkerServiceQueue.async(flags: .barrier) {
                self._handLandmarkerService = newValue
            }
        }
    }
    
    private lazy var cameraFeedService = CameraFeedService()
    private let handLandmarkerServiceQueue = DispatchQueue(label: "handLandmarkerServiceQueue", attributes: .concurrent)
    private let backgroundQueue = DispatchQueue(label: "backgroundQueue")
    weak var inferenceResultDeliveryDelegate: InferenceResultDeliveryDelegate?
    private var isObserving = false
    
    var cnt_speak: Int64 = 0
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .portrait }
    var tSTart = Int64(Date().timeIntervalSince1970)
    private let context = CIContext()
    let audioManager = AudioManager()
    let imageView = UIImageView()
    let yBtn = 20
    
    var memUse = ""
    var lastSent = Int64(Date().timeIntervalSince1970 * 1000.0)
    var videoPaused = false
    
    var frm = UIImage()
    var resultImage = UIImage()
    var camMat3val = ""
    
    var landMarkRead = false
    let file4landmarkData = "landmark.txt"
    let file4color = "isColorInterted.txt"
    
    var webSocketTask: WebSocketTaskConnection?
    var ip_txt = "34.237.62.252"
    var port_txt = "8081"  // demo room
//    var port_txt = "8082"  // magic bridge
    var last_active_time = Int64(Date().timeIntervalSince1970)
    var wsConnected = false
    
    // MARK: - Lifecycle
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        initializeHandLandmarkerServiceOnSessionResumption()
        cameraFeedService.startLiveCameraSession { [weak self] cameraConfiguration in
            DispatchQueue.main.async {
                switch cameraConfiguration {
                case .failed:
                    self?.presentVideoConfigurationErrorAlert()
                case .permissionDenied:
                    self?.presentCameraPermissionsDeniedAlert()
                default:
                    break
                }
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tSTart = Int64(Date().timeIntervalSince1970)
        
        cameraFeedService.delegate = self
        audioManager.delegate = self
        setupImageView()
        
        loadPlaygroundData()
        
        if !camIoWrapper.clearingYouAreHereBoundary() {
            print("Your Are Here surrounding NOT cleared")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.readLandmarkData()
        }
        
        setWebSocket(ip_txt, port_txt)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    // MARK: - HandLandmarker Service
    
    private func initializeHandLandmarkerServiceOnSessionResumption() {
        clearAndInitializeHandLandmarkerService()
        startObserveConfigChanges()
    }
    
    @objc private func clearAndInitializeHandLandmarkerService() {
        handLandmarkerService = nil
        handLandmarkerService = HandLandmarkerService.liveStreamHandLandmarkerService(
            modelPath: InferenceConfigurationManager.sharedInstance.modelPath,
            numHands: InferenceConfigurationManager.sharedInstance.numHands,
            minHandDetectionConfidence: InferenceConfigurationManager.sharedInstance.minHandDetectionConfidence,
            minHandPresenceConfidence: InferenceConfigurationManager.sharedInstance.minHandPresenceConfidence,
            minTrackingConfidence: InferenceConfigurationManager.sharedInstance.minTrackingConfidence,
            liveStreamDelegate: self
        )
    }
    
    private func clearhandLandmarkerServiceOnSessionInterruption() {
        stopObserveConfigChanges()
        handLandmarkerService = nil
    }
    
    private func startObserveConfigChanges() {
        NotificationCenter.default.addObserver(self, selector: #selector(clearAndInitializeHandLandmarkerService), name: InferenceConfigurationManager.notificationName, object: nil)
        isObserving = true
    }
    
    private func stopObserveConfigChanges() {
        if isObserving {
            NotificationCenter.default.removeObserver(self, name: InferenceConfigurationManager.notificationName, object: nil)
        }
        isObserving = false
    }
    
    // MARK: - Alerts
    
    private func presentVideoConfigurationErrorAlert() {
        let alert = UIAlertController(title: "Camera Configuration Failed", message: "There was an error while configuring camera.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        present(alert, animated: true)
    }
    
    private func presentCameraPermissionsDeniedAlert() {
        let alertController = UIAlertController(
            title: "Camera Permissions Denied",
            message: "Camera permissions have been denied for this app. You can change this by going to Settings",
            preferredStyle: .alert
        )
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        let settingsAction = UIAlertAction(title: "Settings", style: .default) { _ in
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
        }
        
        alertController.addAction(cancelAction)
        alertController.addAction(settingsAction)
        
        present(alertController, animated: true)
    }
    
    // MARK: - AudioManagerDelegate
    
    func speaked() {
        cnt_speak += 1
    }
    
    // MARK: - Image View Setup
    
    func setupImageView() {
        view.addSubview(imageView)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = view.bounds
    }
    
    // MARK: - Button Actions
    
    @objc func didBecomeActive() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            // Add functionality if needed
        }
    }
    
    func addWsBtn() {
        let x = 0, w = 110, h = 30, dy = 30
        let y = yBtn + dy
        _ = addButton(x: x, y: y, w: w, h: h, title: "WS Server", color: .blue, selector: #selector(setWebSocketServer))
    }
    
    func delAllButtonsLabels() {
        buttons.forEach { $0.removeFromSuperview() }
        labels.forEach { $0.removeFromSuperview() }
    }
    
    @objc func setWebSocketServer() {
        let model = UIAlertController(title: "WS Server", message: "", preferredStyle: .alert)
        model.addTextField { textField in
            textField.placeholder = "host name/ip address"
            textField.textColor = .blue
            textField.text = self.ip_txt
        }
        model.addTextField { textField in
            textField.placeholder = "port"
            textField.textColor = .blue
            textField.text = self.port_txt
        }
        let save = UIAlertAction(title: "Save", style: .default) { _ in
            let host = model.textFields![0] as UITextField
            let port = model.textFields![1] as UITextField
            self.ip_txt = host.text!
            self.port_txt = port.text!
            self.setWebSocket(self.ip_txt, self.port_txt)
        }
        model.addAction(save)
        model.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(model, animated: true)
    }
    
    // MARK: - WebSocket Setup
    
    func setWebSocket(_ ip: String, _ port: String) {
        webSocketTask = WebSocketTaskConnection(url: URL(string: "ws://" + ip + ":" + port)!)
        webSocketTask?.delegate = self
        socketTryConnect()
    }
    
    func socketTryConnect() {
        webSocketTask?.connect()
        webSocketTask?.send(text: "Hello Socket, are you there?")
        webSocketTask?.listen()
    }
    
    // MARK: - Landmark Data
    
    func readLandmarkData() {
        let dat = readFr(file4landmarkData)
        if dat.count > 0 {
            camIoWrapper.setFeatureBaseImagePoints(dat)
        }
    }
    
    func readIsColorInverted() {
        let dat = readFr(file4color)
        if dat.count > 0 {
            camIoWrapper.set_is_color_inverted(dat)
        }
    }
    
    // MARK: - Playground Data
    
    func loadPlaygroundData(_ scaling: Float = 1.0) {
        let (_, zones) = readPlaygroundObjFileOld()
        let (objs, _) = readPlaygroundObjFile()
        let idNameMapping = getIdNameMappingBoth().components(separatedBy: "\n")
        let objs_new = mappingLoops(objs, idNameMapping)
        let zones_new = mappingLoops(zones, idNameMapping)
        
        var nPnt: Int32 = 0
        for s in objs_new {
            let n = camIoWrapper.newRegion(s)
            print("n = \(n)")
            nPnt += n
        }
        for s in zones_new {
            let n = camIoWrapper.newZone(s)
            print("n = \(n)")
            nPnt += n
        }
        print("nPnt = \(nPnt)")
        
        load_mp3_files()
        
        camIoWrapper.scaleModel(scaling)
    }
    
    func mappingLoops(_ objs: [String], _ mapping: [String]) -> [String] {
        var objs_new = [String]()
        for id_name in mapping {
            let id_nm = id_name.components(separatedBy: "    ")
            for obj in objs {
                if obj.contains(id_nm[0]) {
                    let out = id_nm.count == 4 ? obj.replacingOccurrences(of: id_nm[0], with: id_nm[1] + "\t" + id_nm[3]) : obj.replacingOccurrences(of: id_nm[0], with: id_nm[1])
                    objs_new.append(out)
                    if id_nm.count != 4 {
                        break
                    }
                }
            }
        }
        return objs_new
    }
    
    func load_mp3_files() {
        let names = camIoWrapper.getRegionNames().components(separatedBy: "\n")
        print("mp3 not found: begin")
        var lst = [String]()
        var lst_des = [String]()
        for name in names {
            guard name.count > 0 else { continue }
            let rt = name.replacingOccurrences(of: " ", with: "_")
            let path = Bundle.main.path(forResource: "obj_names/" + rt, ofType: ".mp3")
            if let path = path {
                lst.append(name)
                audioManager.try_load_mp3(name, path: "obj_names/" + rt)
            } else {
                print(name)
            }
            let path_des = Bundle.main.path(forResource: "obj_des/" + rt + "_des", ofType: ".mp3")
            if let path_des = path_des {
                lst_des.append(name + " des")
                audioManager.try_load_mp3(name + " des", path: "obj_des/" + rt + "_des")
            }
        }
        print("mp3 not found: end")
        for l in lst_des {
            print(l)
        }
        audioManager.show_obj_bufs()
        
        for msg in ["Welcome to the Magic Map", "Stylus Straight Upright", "This is an audio test"] {
            let rt = msg.replacingOccurrences(of: " ", with: "_")
            audioManager.try_load_mp3(msg, path: "special_mp3/" + rt)
        }
    }
    
    func readPlaygroundObjFile() -> ([String], [String]) {
        var objs = [String](), zones = [String]()
        let uNG = Bundle.main.url(forResource: "sparse", withExtension: "obj")
        do {
            let contents = try String(contentsOf: uNG!)
            let all_items = contents.components(separatedBy: "o ")
            for item in all_items[1...] {
                let lines = item.components(separatedBy: "\n")
                var obj = lines[0] + "\n"
                for line in lines[1...] {
                    if line.contains("vn ") { break }
                    obj += line + "\n "
                }
                if !obj.contains("GROUND_") {
                    if obj.contains("ZONE_") {
                        zones.append(obj)
                    } else {
                        objs.append(obj)
                    }
                }
            }
        } catch {
            // Handle error
        }
        return (objs, zones)
    }
    
    func readPlaygroundObjFileOld() -> ([String], [String]) {
        var objs = [String](), zones = [String]()
        let uNG = Bundle.main.url(forResource: "20210609 OPTICAL MAP", withExtension: "obj")
        do {
            let contents = try String(contentsOf: uNG!)
            let all_items = contents.components(separatedBy: "s off")
            for item in all_items {
                let tmp = item.components(separatedBy: "o ")
                if tmp.count > 1 {
                    let name = tmp[1].components(separatedBy: "\n")[0]
                    if !name.contains("GROUND_") {
                        if name.contains("ZONE_") {
                            zones.append(tmp[1])
                        } else {
                            objs.append(tmp[1])
                        }
                    }
                }
            }
        } catch {
            // Handle error
        }
        return (objs, zones)
    }
    
    // MARK: - Frame Processing
    
    func processFrame(_ image: UIImage) {
        resultImage = camIoWrapper.procImage(image)
        let txt = camIoWrapper.getState()
        audioManager.processState(iState: camIoWrapper.getStateIdx(), stylusString: txt)
        imageView.image = resultImage.withText("Memory Use = \(Memory.formattedMemoryFootprint())", at: CGPoint(x: 20, y: 200))
    }
}

// MARK: - CameraFeedServiceDelegate

extension ViewController: CameraFeedServiceDelegate {
    func didOutput(sampleBuffer: CMSampleBuffer, orientation: UIImage.Orientation) {
        if let camData = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data {
            let matrix: matrix_float3x3 = camData.withUnsafeBytes { $0.pointee }
            camIoWrapper.setCamMat3val("\(matrix[0][0]) \(matrix[2][0]) \(matrix[2][1])")
        }
        
        let currentTimeMs = Date().timeIntervalSince1970 * 1000
        DispatchQueue.main.sync { [weak self] in
            self?.handLandmarkerService?.detectAsync(
                sampleBuffer: sampleBuffer,
                orientation: orientation,
                timeStamps: Int(currentTimeMs)
            )
        }
        
        DispatchQueue.main.sync {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
            
            let image = UIImage(cgImage: cgImage)
            frm = image
            processFrame(image)
        }
        
        let dt0 = Int64(Date().timeIntervalSince1970) - tSTart
        let dt = Int64(Date().timeIntervalSince1970) - last_active_time
        if dt0 < 3600 && dt > 60 {
            webSocketTask?.send(text: "ping, cnt_speak = \(cnt_speak)")
            last_active_time = Int64(Date().timeIntervalSince1970)
            if !wsConnected {
                socketTryConnect()
            }
        }
    }
    
    func sessionWasInterrupted(canResumeManually resumeManually: Bool) {
        clearhandLandmarkerServiceOnSessionInterruption()
    }
    
    func sessionInterruptionEnded() {
        initializeHandLandmarkerServiceOnSessionResumption()
    }
    
    func didEncounterSessionRuntimeError() {
        clearhandLandmarkerServiceOnSessionInterruption()
    }
}

// MARK: - HandLandmarkerServiceLiveStreamDelegate

extension ViewController: HandLandmarkerServiceLiveStreamDelegate {
    func handLandmarkerService(_ handLandmarkerService: HandLandmarkerService, didFinishDetection result: ResultBundle?, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let weakSelf = self else { return }
            weakSelf.inferenceResultDeliveryDelegate?.didPerformInference(result: result)
            guard let handLandmarkerResult = result?.handLandmarkerResults.first as? HandLandmarkerResult else { return }
            var found = false
            for handLandmarks in handLandmarkerResult.landmarks {
                let transformedHandLandmarks = handLandmarks.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
                let thumb = transformedHandLandmarks[4]
                let index = transformedHandLandmarks[8]
                found = true
                weakSelf.camIoWrapper.set2FingerTips("\(thumb.x) \(thumb.y) \(index.x) \(index.y)")
            }
            let val = -1.01
            if !found {
                weakSelf.camIoWrapper.set2FingerTips("\(val) \(val) \(val) \(val)")
            }
        }
    }
}

// MARK: - WebSocketConnectionDelegate

extension ViewController: WebSocketConnectionDelegate {
    func onConnected(connection: WebSocketConnection) {
        last_active_time = Int64(Date().timeIntervalSince1970)
        wsConnected = true
    }
    
    func onDisconnected(connection: WebSocketConnection, error: Error?) {
        wsConnected = false
    }
    
    func onError(connection: WebSocketConnection, error: Error) {
        wsConnected = false
    }
    
    func onMessage(connection: WebSocketConnection, data: Data) {
        print("Received data message")
    }
    
    func onMessage(connection: WebSocketConnection, text: String) {
        last_active_time = Int64(Date().timeIntervalSince1970)
        print("Received text message: \(text)")
        
        if text.contains("image, please") {
            guard let txt = frm.base64 else { return }
            webSocketTask?.send(text: txt)
        }
        if text.contains("result image") {
            guard let txt = resultImage.base64 else { return }
            webSocketTask?.send(text: txt)
        }
        if text.contains("cam mat & image") {
            guard let txt = frm.base64 else { return }
            webSocketTask?.send(text: "\(camMat3val)___cam+img___\(txt)")
        }
        if text.contains("New Landmark Data:") {
            camIoWrapper.resetFeatureBase()
            let dat = text.components(separatedBy: "Landmark Data:")[1]
            camIoWrapper.setFeatureBaseImagePoints(dat)
            writeTo(fn: file4landmarkData, dat: dat)
        }
        if text.contains("vol+") {
            audioManager.volInc()
        }
        if text.contains("vol-") {
            audioManager.volDec()
        }
        if text.contains("skeri: hello") {
            DispatchQueue.main.asyncAfter(deadline: .now()) {
                for _ in 1..<10 {
                    self.audioManager.processState(iState: 4, stylusString: "James from Smith-Kettle-well says hello")
                }
            }
        }
        if text.contains("skeri: This is an audio test") {
            DispatchQueue.main.asyncAfter(deadline: .now()) {
                for _ in 1..<100 {
                    self.audioManager.processState(iState: 4, stylusString: "This is an audio test,------, ")
                }
            }
        }
    }
}

// MARK: - UIImage Extension

extension UIImage {
    var base64: String? {
        return self.jpegData(compressionQuality: 0.8)?.base64EncodedString()
    }
}

// MARK: - String Extension

extension String {
    var imageFromBase64: UIImage? {
        guard let imageData = Data(base64Encoded: self, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return UIImage(data: imageData)
    }
}

