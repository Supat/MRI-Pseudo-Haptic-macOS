//
//  CameraPreviewView.swift
//
//  Renders the latest CVPixelBuffer using a Core Image backed NSView.
//  We avoid AVSampleBufferDisplayLayer because the Vimba frames already
//  live in IOSurface-backed pixel buffers and Core Image handles them
//  efficiently.
//

import SwiftUI
import AppKit
import CoreImage
import CoreVideo
import Metal
import MetalKit

struct CameraPreviewView: NSViewRepresentable {

    let pixelBuffer: CVPixelBuffer

    func makeNSView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = MTKView(frame: .zero, device: device)
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = context.coordinator
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.coordinator.configure(view: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.pixelBuffer = pixelBuffer
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var pixelBuffer: CVPixelBuffer?
        private var ciContext: CIContext?
        private var commandQueue: MTLCommandQueue?

        func configure(view: MTKView) {
            guard let device = view.device else { return }
            commandQueue = device.makeCommandQueue()
            ciContext = CIContext(mtlDevice: device,
                                  options: [.workingColorSpace: NSNull()])
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

        func draw(in view: MTKView) {
            guard let pixelBuffer = pixelBuffer,
                  let ciContext = ciContext,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let drawable = view.currentDrawable else { return }

            let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)

            // Aspect-fit the source image into the drawable.
            let drawableSize = view.drawableSize
            let sx = drawableSize.width / sourceImage.extent.width
            let sy = drawableSize.height / sourceImage.extent.height
            let scale = min(sx, sy)
            let scaled = sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

            let dx = (drawableSize.width - scaled.extent.width) * 0.5
            let dy = (drawableSize.height - scaled.extent.height) * 0.5
            let centered = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))

            let bounds = CGRect(origin: .zero, size: drawableSize)
            ciContext.render(centered,
                             to: drawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: bounds,
                             colorSpace: CGColorSpaceCreateDeviceRGB())

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
