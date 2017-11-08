//
//  ViewController.swift
//  gauge
//
//  Created by Wojciech Ganczarski on 30/10/2017.
//  Copyright © 2017 Video Scales. All rights reserved.
//

import UIKit
import AVFoundation
import Vision

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
	
	@IBOutlet weak var unitControl: UISegmentedControl!
	@IBOutlet weak var weightLabel: UILabel!
	@IBOutlet weak var zeroButton: UIBarButtonItem!
	@IBOutlet weak var cameraView: UIView!
	@IBOutlet weak var highlightView: UIView! {
		didSet {
			self.highlightView?.layer.borderColor = UIColor.white.cgColor
			self.highlightView?.layer.borderWidth = 2
		}
	}
	
	private let visionSequenceHandler = VNSequenceRequestHandler()
	private lazy var cameraLayer: AVCaptureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
	private lazy var captureSession: AVCaptureSession = {
		let session = AVCaptureSession()
		session.sessionPreset = AVCaptureSession.Preset.photo
		let backCamera:AVCaptureDevice? = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
		// TODO: find out how to set max possible frame rate
		//backCamera?.activeVideoMaxFrameDuration.seconds
		do {
			try backCamera?.lockForConfiguration()
			//backCamera?.activeFormat =
			//backCamera?.activeVideoMaxFrameDuration = CMTimeMake(1, 60)
			backCamera?.unlockForConfiguration()
		} catch {
			return session
		}
		guard
			let device = backCamera,
			let input = try? AVCaptureDeviceInput(device: device)
			else { return session }
		session.addInput(input)
		return session
	}()
	
	private var springStiffness: Double! // [N/m]
	private var springMass: Double! // [kg]
	private var panMass: Double! // [kg]
	
	private var unitRatio: Double!
	private var fractionalDigits: UInt8!
	
	private var currentValue: Double!
	private var zeroAdjustment: Double = 0
	
	private var lastObservation: VNDetectedObjectObservation?
	
	override func viewDidLoad() {
		super.viewDidLoad()
		// Do any additional setup after loading the view, typically from a nib.
		
		// TODO: move to settings
		springMass = 0.0025
		panMass = 0.0215
		// TODO: (2) calculate based on spring's dimensions
		springStiffness = 218
		
		// TODO: move to settings
		unitControl.selectedSegmentIndex = 0
		updateUnits()
		
		self.weightLabel.layer.zPosition = self.cameraView.layer.zPosition + 1
		
		// hide the tracking area on load
		self.highlightView.frame = .zero
		
		self.cameraLayer.videoGravity = AVLayerVideoGravity.resizeAspectFill
		
		// make the camera appear on the screen
		self.cameraView.layer.addSublayer(self.cameraLayer)
		
		// register to receive buffers from the camera
		let videoOutput = AVCaptureVideoDataOutput()
		videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "VideoScalesQueue"))
		self.captureSession.addOutput(videoOutput)
		
		// begin the session
		self.captureSession.startRunning()
	}
	
	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		
		// make sure the layer is the correct size
		self.cameraLayer.frame = self.cameraView.bounds
	}
	
	override func didReceiveMemoryWarning() {
		super.didReceiveMemoryWarning()
		// Dispose of any resources that can be recreated.
	}
	
	func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		guard
			// make sure the pixel buffer can be converted
			let pixelBuffer: CVPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
			// make sure that there is a previous observation we can feed into the request
			let lastObservation = self.lastObservation
			else { return }
		
		// create the request
		let request = VNTrackObjectRequest(detectedObjectObservation: lastObservation, completionHandler: self.handleVisionRequestUpdate)
		// set the accuracy to high
		request.trackingLevel = .accurate
		
		// perform the request
		do {
			try self.visionSequenceHandler.perform([request], on: pixelBuffer)
		} catch {
			// TODO: handle the error appropriately
		}
	}
	
	private let fft = FFT()
	private var yBuffer: [(Double, TimeInterval)] = []
	
	private func handleVisionRequestUpdate(_ request: VNRequest, error: Error?) {
		let timestamp: TimeInterval = NSDate().timeIntervalSince1970
		// Dispatch to the main queue because we are touching non-atomic, non-thread safe properties of the view controller
		DispatchQueue.main.async {
			// make sure we have an actual result
			guard let newObservation = request.results?.first as? VNDetectedObjectObservation else { return }
			
			// prepare for next loop
			self.lastObservation = newObservation
			
			// check the confidence level before updating the UI
			guard newObservation.confidence >= 0.3 else {
				// hide the rectangle when we lose accuracy so the user knows something is wrong
				self.highlightView.frame = .zero
				return
			}
			
			// calculate view rect
			var transformedRect = newObservation.boundingBox
			transformedRect.origin.y = 1 - transformedRect.origin.y
			let convertedRect = self.cameraLayer.layerRectConverted(fromMetadataOutputRect: transformedRect)
			
			self.yBuffer.append((Double(convertedRect.midY), timestamp))
			let bufferSize = self.yBuffer.count
			if (bufferSize == 32 || bufferSize == 64 || bufferSize == 128 || bufferSize == 256) {
				let yValues = self.yBuffer.map {$0.0}
				let fps = Double(bufferSize) / (self.yBuffer.last!.1 - self.yBuffer.first!.1)
				let frequency = self.fft.calculate(yValues, fps: fps)
				if (bufferSize > 256) {
					self.yBuffer = Array(self.yBuffer.suffix(63))
				}
				self.currentValue = self.unitRatio * self.calculateWeight(1 / frequency.0)
				self.weightLabel.text = String(format: self.decimalFormat, self.currentValue - self.unitRatio * self.zeroAdjustment);
			}
			
			// move the highlight view
			self.highlightView.frame = convertedRect
		}
	}
	
	fileprivate func calculateWeight(_ period: Double) -> Double {
		return (pow(period / (2 * Double.pi), 2) * springStiffness) - (springMass / 3) - panMass
	}
	
	fileprivate func updateUnits() {
		switch unitControl.selectedSegmentIndex {
		case 0: // [g]
			unitRatio = 1000
			fractionalDigits = 0
			break
		case 1: // [kg]
			unitRatio = 1
			fractionalDigits = 3
			break
		case 2: // [oz]
			unitRatio = 35.2739619
			fractionalDigits = 1
			break
		case 3: // [lbs]
			unitRatio = 2.20462262
			fractionalDigits = 2
			break
		default:
			break
		}
	}
	
	fileprivate var decimalFormat: String {
		get {
			return "%.\(fractionalDigits.description)f"
		}
	}
	
	@IBAction func onTap(_ sender: UITapGestureRecognizer) {
		self.yBuffer.removeAll()
		self.weightLabel.text = "Computing..."
		
		// get the center of the tap
		self.highlightView.frame.size = CGSize(width: 100, height: 100)
		self.highlightView.center = sender.location(in: self.view)
		
		// convert the rect for the initial observation
		let originalRect = self.highlightView.frame
		var convertedRect = self.cameraLayer.metadataOutputRectConverted(fromLayerRect: originalRect)
		convertedRect.origin.y = 1 - convertedRect.origin.y
		
		// set the observation
		let newObservation = VNDetectedObjectObservation(boundingBox: convertedRect)
		self.lastObservation = newObservation
	}
	
	@IBAction func onUnitChange(_ sender: UISegmentedControl) {
		updateUnits()
	}
	
	@IBAction func onZero(_ sender: UIBarButtonItem) {
		if (self.currentValue != nil) {
			self.zeroAdjustment = self.currentValue / self.unitRatio
		}
	}
	
	@IBAction func onReset(_ sender: UIBarButtonItem) {
		self.lastObservation = nil
		self.highlightView.frame = .zero
		self.yBuffer.removeAll()
		self.weightLabel.text = "-"
	}
}

