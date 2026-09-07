package app.roomscope.capture

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.Image
import android.net.Uri
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.os.Handler
import android.os.Looper
import android.view.View
import com.google.ar.core.*
import com.google.ar.core.exceptions.NotYetAvailableException
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.*
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.UUID
import org.json.JSONObject
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

class RoomCapturePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var activity: Activity? = null
    private var sink: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var session: Session? = null
    private var running = false
    private var recording: File? = null
    private var preview: CaptureView? = null
    private val poseTrackId = UUID.fromString("8d07f9ed-3286-4c80-8ea6-847dd40de213")

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods = MethodChannel(binding.binaryMessenger, "roomscope/capture")
        events = EventChannel(binding.binaryMessenger, "roomscope/frames")
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        binding.platformViewRegistry.registerViewFactory("roomscope/preview",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, id: Int, args: Any?): PlatformView {
                    return CaptureView(context).also { preview = it }
                }
            })
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { release(); activity = null }
    override fun onDetachedFromActivity() { release(); activity = null }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        release(); methods.setMethodCallHandler(null); events.setStreamHandler(null)
    }
    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) { sink = eventSink }
    override fun onCancel(arguments: Any?) { sink = null }
    private fun emit(data: Map<String, Any?>) { main.post { sink?.success(data) } }

    private fun start() {
        val host = activity ?: throw IllegalStateException("camera: Activity unavailable")
        if (host.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED)
            throw IllegalStateException("camera permission is required")
        if (ArCoreApk.getInstance().requestInstall(host, true) == ArCoreApk.InstallStatus.INSTALL_REQUESTED)
            throw IllegalStateException("ar_installing")
        synchronized(lock) {
            if (session == null) {
                session = Session(host).also { created ->
                    val config = Config(created).apply {
                        focusMode = Config.FocusMode.AUTO
                        updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                    }
                    if (created.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                        config.depthMode = Config.DepthMode.AUTOMATIC
                    }
                    created.configure(config)
                }
            }
            if (!running) { session!!.resume(); running = true }
        }
        preview?.surface?.onResume()
    }
    private fun stopRecording(): Map<String, Any>? = synchronized(lock) {
        val file = recording ?: return@synchronized null
        val current = session
        if (current == null || current.recordingStatus != RecordingStatus.OK) {
            recording = null
            throw IllegalStateException("Video recording did not complete successfully")
        }
        current.stopRecording()
        recording = null
        mapOf("path" to file.absolutePath, "timeline" to "ARCore dataset",
            "poseTrackId" to poseTrackId.toString())
    }
    private fun pause() {
        synchronized(lock) {
            stopRecording()
            if (running) session?.pause()
            running = false
        }
        preview?.surface?.onPause()
    }
    private fun release() {
        synchronized(lock) {
            try { stopRecording() } catch (_: Exception) { }
            if (running) session?.pause()
            running = false
            session?.close(); session = null
        }
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> { start(); result.success(null) }
                "pause" -> { pause(); result.success(null) }
                "reset" -> { release(); start(); result.success(null) }
                "record" -> {
                    val directory = call.argument<String>("directory") ?: error("Missing capture directory")
                    val host = activity ?: error("camera unavailable")
                    val dir = File(directory).canonicalFile
                    val appData = File(host.applicationInfo.dataDir).canonicalFile
                    require(dir.path.startsWith(appData.path + File.separator))
                    require(dir.isDirectory)
                    val file = File(dir, "capture.mp4")
                    require(!file.exists()) { "Capture already exists" }
                    synchronized(lock) {
                        check(running && recording == null) { "camera is not ready" }
                        val current = session ?: error("camera is unavailable")
                        val config = RecordingConfig(current)
                            .setMp4DatasetUri(Uri.fromFile(file)).setAutoStopOnPause(true)
                        config.addTrack(Track(current).setId(poseTrackId)
                            .setMimeType("application/vnd.roomscope.pose+json"))
                        current.startRecording(config)
                        recording = file
                    }
                    result.success(null)
                }
                "stopRecording" -> result.success(stopRecording())
                "dispose" -> { release(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            val code = when {
                error.message?.contains("ar_installing") == true -> "ar_installing"
                error is com.google.ar.core.exceptions.UnavailableDeviceNotCompatibleException -> "unsupported"
                else -> "camera"
            }
            result.error(code,
                error.message ?: "Camera unavailable", null)
        }
    }

    private fun rgb256(image: Image): ByteArray {
        val output = ByteArray(256*256*3)
        val planes = image.planes
        for (v in 0 until 256) for (u in 0 until 256) {
            val x = (u*image.width/256).coerceAtMost(image.width-1)
            val y = (v*image.height/256).coerceAtMost(image.height-1)
            val yy = (planes[0].buffer.get(y*planes[0].rowStride+x*planes[0].pixelStride).toInt() and 255)-16
            val uu = (planes[1].buffer.get((y/2)*planes[1].rowStride+(x/2)*planes[1].pixelStride).toInt() and 255)-128
            val vv = (planes[2].buffer.get((y/2)*planes[2].rowStride+(x/2)*planes[2].pixelStride).toInt() and 255)-128
            val offset = (v*256+u)*3
            output[offset] = ((298*yy+409*vv+128)/256).coerceIn(0,255).toByte()
            output[offset+1] = ((298*yy-100*uu-208*vv+128)/256).coerceIn(0,255).toByte()
            output[offset+2] = ((298*yy+516*uu+128)/256).coerceIn(0,255).toByte()
        }
        return output
    }

    private inner class CaptureView(context: Context) : PlatformView, GLSurfaceView.Renderer {
        val surface = GLSurfaceView(context)
        private val positions = floats(floatArrayOf(-1f,-1f,1f,-1f,-1f,1f,1f,1f))
        private val uv = floats(FloatArray(8))
        private var texture = 0
        private var program = 0
        private var lastFrame = 0L
        private var width = 1
        private var height = 1
        private var hadError = false
        init {
            surface.setEGLContextClientVersion(2)
            surface.preserveEGLContextOnPause = true
            surface.setRenderer(this)
        }
        override fun getView(): View = surface
        override fun dispose() { surface.onPause(); if (preview === this) preview = null }
        override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
            val ids = IntArray(1); GLES20.glGenTextures(1, ids, 0); texture = ids[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
            for (name in intArrayOf(GLES20.GL_TEXTURE_MIN_FILTER,GLES20.GL_TEXTURE_MAG_FILTER))
                GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,name,GLES20.GL_LINEAR)
            for (name in intArrayOf(GLES20.GL_TEXTURE_WRAP_S,GLES20.GL_TEXTURE_WRAP_T))
                GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,name,GLES20.GL_CLAMP_TO_EDGE)
            val vertex = shader(GLES20.GL_VERTEX_SHADER,
                "attribute vec2 p; attribute vec2 t; varying vec2 uv; void main(){uv=t;gl_Position=vec4(p,0.,1.);}")
            val fragment = shader(GLES20.GL_FRAGMENT_SHADER,
                "#extension GL_OES_EGL_image_external : require\nprecision mediump float; uniform samplerExternalOES camera; varying vec2 uv; void main(){gl_FragColor=texture2D(camera,uv);}")
            program = GLES20.glCreateProgram()
            GLES20.glAttachShader(program,vertex); GLES20.glAttachShader(program,fragment)
            GLES20.glLinkProgram(program)
            GLES20.glDeleteShader(vertex); GLES20.glDeleteShader(fragment)
            val linked = IntArray(1)
            GLES20.glGetProgramiv(program,GLES20.GL_LINK_STATUS,linked,0)
            if (linked[0] == 0) {
                GLES20.glDeleteProgram(program); program = 0
                emit(mapOf("error" to "Camera preview could not initialise on this device."))
            }
        }
        override fun onSurfaceChanged(gl: GL10?, w: Int, h: Int) {
            width=w; height=h; GLES20.glViewport(0,0,w,h)
        }
        override fun onDrawFrame(gl: GL10?) {
            GLES20.glClearColor(.05f,.08f,.1f,1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            synchronized(lock) {
                val current = session ?: return
                if (!running || texture == 0 || program == 0) return
                try {
                    @Suppress("DEPRECATION")
                    val rotation = activity?.windowManager?.defaultDisplay?.rotation ?: 0
                    current.setDisplayGeometry(rotation,width,height)
                    current.setCameraTextureName(texture)
                    val frame = current.update()
                    positions.rewind(); uv.rewind()
                    frame.transformCoordinates2d(Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES,
                        positions, Coordinates2d.TEXTURE_NORMALIZED,uv)
                    drawBackground()
                    if (frame.timestamp == 0L || frame.timestamp-lastFrame < 250_000_000L) return
                    lastFrame=frame.timestamp
                    val camera = frame.camera
                    val pose = FloatArray(16); camera.pose.toMatrix(pose,0)
                    val intr = camera.imageIntrinsics
                    val dimensions = intr.imageDimensions
                    val focal = intr.focalLength
                    val center = intr.principalPoint
                    val k = listOf(focal[0]*256.0/dimensions[0], focal[1]*256.0/dimensions[1],
                        center[0]*256.0/dimensions[0], center[1]*256.0/dimensions[1])
                    if (recording != null && current.recordingStatus == RecordingStatus.OK) {
                        val metadata = JSONObject(mapOf("timestamp" to frame.timestamp/1e9,
                            "cameraToWorld" to pose.map { it.toDouble() }, "intrinsics256" to k))
                        try {
                            frame.recordTrackData(poseTrackId, ByteBuffer.wrap(metadata.toString().toByteArray(Charsets.UTF_8)))
                        } catch (error: IllegalStateException) {
                            // ARCore may reject a sample briefly under load. Keep
                            // the video and mapping alive, then try the next frame.
                            if (current.recordingStatus != RecordingStatus.OK) throw error
                        }
                    }
                    val points = ArrayList<Double>()
                    val anchors = ArrayList<Double>()
                    frame.acquirePointCloud().use { cloud ->
                        val values = cloud.points
                        val inverse = camera.pose.inverse()
                        var i = 0
                        while (i+3 < values.limit() && points.size < 6000) {
                            if (values[i+3] >= .5f) {
                                val world = floatArrayOf(values[i],values[i+1],values[i+2])
                                points.addAll(world.map { it.toDouble() })
                                val local = inverse.transformPoint(world)
                                val depth = -local[2].toDouble()
                                if (depth in .25..8.0) {
                                    val u = k[0]*local[0]/depth+k[2]
                                    val v = k[1]*(-local[1])/depth+k[3]
                                    if (u in 0.0..255.99 && v in 0.0..255.99)
                                        anchors.addAll(listOf(u,v,depth))
                                }
                            }
                            i += 4
                        }
                    }
                    var nativeDepth = false
                    if (camera.trackingState == TrackingState.TRACKING &&
                        current.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                        try {
                            frame.acquireDepthImage16Bits().use { depthImage ->
                                val plane = depthImage.planes[0]
                                val buffer = plane.buffer.order(ByteOrder.LITTLE_ENDIAN)
                                val dfx = focal[0] * depthImage.width.toFloat() / dimensions[0]
                                val dfy = focal[1] * depthImage.height.toFloat() / dimensions[1]
                                val dcx = center[0] * depthImage.width.toFloat() / dimensions[0]
                                val dcy = center[1] * depthImage.height.toFloat() / dimensions[1]
                                val step = maxOf(2, minOf(depthImage.width, depthImage.height) / 60)
                                depthLoop@ for (v in step/2 until depthImage.height step step) {
                                    for (u in step/2 until depthImage.width step step) {
                                        if (points.size >= 18000) break@depthLoop
                                        val offset = v*plane.rowStride + u*plane.pixelStride
                                        if (offset < 0 || offset+1 >= buffer.limit()) continue
                                        val mm = buffer.getShort(offset).toInt() and 0xffff
                                        if (mm !in 250..8000) continue
                                        val z = mm/1000f
                                        val local = floatArrayOf(
                                            (u.toFloat()-dcx)*z/dfx,
                                            -(v.toFloat()-dcy)*z/dfy,
                                            -z
                                        )
                                        val world = camera.pose.transformPoint(local)
                                        points.addAll(world.map { it.toDouble() })
                                        nativeDepth = true
                                    }
                                }
                            }
                        } catch (_: NotYetAvailableException) {
                            // ARCore depth generally needs several tracked frames first.
                        } catch (_: IllegalStateException) {
                            // Keep feature-point and MiDaS fallback alive if depth drops out.
                        }
                    }
                    var rgb: ByteArray? = null
                    if (!nativeDepth) {
                        try { frame.acquireCameraImage().use { rgb = rgb256(it) } }
                        catch (_: NotYetAvailableException) { }
                    }
                    emit(mapOf("timestamp" to frame.timestamp/1e9,
                        "tracking" to (camera.trackingState == TrackingState.TRACKING),
                        "pose" to pose.map { it.toDouble() }, "intrinsics" to k,
                        "anchors" to anchors, "points" to points, "rgb" to rgb,
                        "nativeDepth" to nativeDepth))
                    hadError = false
                } catch (error: Exception) {
                    if (!hadError) emit(mapOf("error" to "Camera tracking was interrupted. Retry camera access."))
                    hadError = true
                }
            }
        }
        private fun drawBackground() {
            GLES20.glDisable(GLES20.GL_DEPTH_TEST)
            GLES20.glUseProgram(program)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES,texture)
            GLES20.glUniform1i(GLES20.glGetUniformLocation(program,"camera"),0)
            val p = GLES20.glGetAttribLocation(program,"p")
            val t = GLES20.glGetAttribLocation(program,"t")
            positions.rewind(); uv.rewind()
            GLES20.glEnableVertexAttribArray(p); GLES20.glEnableVertexAttribArray(t)
            GLES20.glVertexAttribPointer(p,2,GLES20.GL_FLOAT,false,0,positions)
            GLES20.glVertexAttribPointer(t,2,GLES20.GL_FLOAT,false,0,uv)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP,0,4)
            GLES20.glDisableVertexAttribArray(p); GLES20.glDisableVertexAttribArray(t)
        }
        private fun shader(type: Int, source: String): Int {
            val id = GLES20.glCreateShader(type)
            GLES20.glShaderSource(id,source); GLES20.glCompileShader(id)
            return id
        }
        private fun floats(data: FloatArray): FloatBuffer = ByteBuffer.allocateDirect(data.size*4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(data); rewind() }
    }
}
