package app.wayveil

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.HardwareRenderer
import android.graphics.PixelFormat
import android.graphics.RenderNode
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.annotation.RequiresApi
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.viewinterop.AndroidView
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.SystemClock
import android.view.Choreographer
import android.view.HapticFeedbackConstants
import android.view.Surface
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.MotionDurationScale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.graphics.createBitmap
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.coroutineContext
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.round
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.roundToInt

private const val CLOSE_SECONDS = .75f
// The C2 glyph is symmetric under a half turn, so any multiple of it is a resting pose.
private const val HALF_TURN = PI.toFloat()

private fun smoothstep(edge0: Float, edge1: Float, x: Float): Float {
    val t = ((x - edge0) / (edge1 - edge0)).coerceIn(0f, 1f)
    return t * t * (3f - 2f * t)
}

/**
 * The value-noise lattice for portal.agsl, one hash per texel with its period of 256 in both axes.
 * Hashes live in alpha, which colour management leaves alone. The integer hash keeps shared cell corners identical on every GPU.
 */
private fun portalNoise() = createBitmap(256, 256).apply {
    setPixels(IntArray(256 * 256) { index ->
        val x = index % 256
        var n = (x * 34 + 1) * x % 256 + index / 256
        n = (n * 34 + 1) * n % 256
        n shl 24
    }, 0, 256, 0, 0, 256, 256)
}

/**
 * Waits for the next vsync and returns its time. Waiting on Choreographer rather than withFrameNanos keeps the
 * portal's frames from running Compose's recomposition loop when nothing on screen needs recomposing.
 */
private suspend fun awaitVsync(): Long = suspendCancellableCoroutine { continuation ->
    val callback = Choreographer.FrameCallback { continuation.resume(it) }
    Choreographer.getInstance().postFrameCallback(callback)
    continuation.invokeOnCancellation { Choreographer.getInstance().removeFrameCallback(callback) }
}

/** Remembers tunnel transitions and integrates the springs that part, turn and lock the two logo crescents. */
private class PortalMotion(var wasLit: Boolean, var wasConnected: Boolean) {
    var closeAt = -1L
    var impactAt = -1L
    var holdPower = 0f
    var holdBusy = 0f
    var split = 0f
    var splitVelocity = 0f
    var spin = 0f
    var spinVelocity = 0f
    var spinTarget = Float.NaN

    fun step(dt: Float, connecting: Boolean, close: Float, speed: Float) {
        if (dt <= 0f) return
        val splitTarget = when {
            close < .45f -> .7f
            connecting -> 1f
            else -> 0f
        }
        val h = dt / 4f
        repeat(4) {
            // Parting is critically damped; locking overshoots so the crescents visibly clack together.
            val locking = splitTarget < split
            splitVelocity += ((if (locking) 320f else 45f) * (splitTarget - split) - (if (locking) 14f else 13f) * splitVelocity) * h
            split += splitVelocity * h
            if (connecting) {
                spinTarget = Float.NaN
                spinVelocity += (1.8f * speed - spinVelocity) * (1f - exp(-h * 1.5f))
            } else {
                if (spinTarget.isNaN()) spinTarget = (if (spinVelocity > .2f) ceil(spin / HALF_TURN) else round(spin / HALF_TURN)) * HALF_TURN
                // Closing unwinds half a turn slowly; otherwise the spin snaps forward into the lock with the crescents.
                val closing = close < 1f
                spinVelocity += ((if (closing) 40f else 320f) * (spinTarget - spin) - (if (closing) 11.4f else 14f) * spinVelocity) * h
            }
            spin += spinVelocity * h
        }
        // Settled springs snap to rest so the shader can skip the layers they drive.
        if (abs(split - splitTarget) < .0005f && abs(splitVelocity) < .005f) {
            split = splitTarget
            splitVelocity = 0f
        }
        if (!connecting && close >= 1f && abs(spin - spinTarget) < .001f && abs(spinVelocity) < .01f) {
            spinTarget -= floor(spinTarget / (2f * HALF_TURN)) * 2f * HALF_TURN
            spin = spinTarget
            spinVelocity = 0f
        }
    }
}

/**
 * Places the packets of light that run round the ring while it is connected: three along the inner wire, three the other way along the outer one.
 * The shader gets their heads ready-made, so it does not work out the same six angles for every pixel.
 */
internal object PortalTraffic {
    /** A fixed random number per packet that sets where it starts, how fast it runs and how long its tail is. */
    private val seeds = floatArrayOf(.5524f, .8349f, .8579f, .6066f, .4873f, .2637f)

    /** Writes four floats per packet into [into]: the unit vector from the ring's centre to its head, how fast its tail fades, and 0. */
    fun place(time: Float, into: FloatArray) {
        for (i in seeds.indices) {
            val seed = seeds[i]
            val direction = if (i < 3) 1f else -1f
            val head = i * 2.1f + seed * 6f + direction * time * (4f + 2.5f * seed)
            into[i * 4] = cos(head)
            into[i * 4 + 1] = sin(head)
            into[i * 4 + 2] = 1.3f + 1.2f * seed
            into[i * 4 + 3] = 0f
        }
    }
}

/**
 * Places the one light that shades the whole portal: the ring's reflection, glint and highlight, and the logo's gloss and shadow.
 * It circles slowly at rest and leans towards the edge that the tilt turned to the viewer, so all of them follow the hand together.
 * The iOS port in PortalMotion.swift mirrors this object.
 */
internal object PortalLight {
    /** Writes into [into] the unit vector towards the light (x right, y up, z towards the viewer) and how far tilt has drawn it down, 0..1. */
    fun place(time: Float, tiltX: Float, tiltY: Float, into: FloatArray) {
        val lean = smoothstep(.04f, .5f, sqrt(tiltX * tiltX + tiltY * tiltY).coerceAtMost(1f))
        val angle = time * .65f
        val orbit = .65f * (1f - .7f * lean)
        val x = cos(angle) * orbit - tiltX * 1.3f
        val y = sin(angle) * orbit - tiltY * 1.3f
        val length = sqrt(x * x + y * y + .81f)
        into[0] = x / length
        into[1] = y / length
        into[2] = .9f / length
        into[3] = lean
    }
}

/**
 * The page's vertical gradient, in window pixels from the top of the window. The portal's surface lies under the window
 * and paints this gradient itself where the ring fades out, so the two meet without a seam.
 */
internal class PortalBackdrop(val top: Color, val bottom: Color, val endY: Float) {
    val brush = Brush.verticalGradient(listOf(top, bottom), endY = endY)
}

/** What the portal shows in the current frame: the frame loop writes it and the renderers read it, so writing it redraws nothing. */
private class PortalFrame(var power: Float, var busy: Float) {
    var time = 0f
    var age = 10f
    var close = 1f
    var impact = 10f
    var split = 0f
    var spin = 0f
    var spinBlur = 0f
    var tiltX = 0f
    var tiltY = 0f
    var press = 0f
    // Where the portal's top edge sits in the window, to line the painted page up with the real one.
    var windowTop = 0f
    var animating = false
}

/**
 * Draws the portal on a surface of its own under the window, so a portal frame redraws only the portal:
 * the rest of the screen is neither recomposed nor re-rendered on every frame.
 */
@RequiresApi(33)
private class PortalSurface(context: Context, private val shader: RuntimeShader) : SurfaceView(context), SurfaceHolder.Callback {
    private val renderer = HardwareRenderer()
    private val node = RenderNode("portal")
    private val paint = android.graphics.Paint().also { it.shader = shader }
    private var ready = false
    private var laidOut = false
    /** Sets the uniforms that change only with layout, from the surface's size in pixels. */
    var layout: (RuntimeShader, Float, Float) -> Unit = { _, _, _ -> }
        set(value) { field = value; laidOut = false }
    /** Sets the uniforms that change every frame. */
    var animate: (RuntimeShader) -> Unit = {}

    /** Has the next frame set the layout uniforms again, after the portal moved. */
    fun relayout() { laidOut = false }

    init {
        holder.setFormat(PixelFormat.RGBA_8888)
        holder.addCallback(this)
        renderer.setContentRoot(node)
        renderer.isOpaque = true
    }

    fun draw(vsyncNanos: Long = System.nanoTime()) {
        if (!ready || width == 0 || height == 0) return
        if (!laidOut) {
            layout(shader, width.toFloat(), height.toFloat())
            laidOut = true
        }
        animate(shader)
        val canvas = node.beginRecording(width, height)
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
        node.endRecording()
        renderer.createRenderRequest().setVsyncTime(vsyncNanos).syncAndDraw()
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        renderer.setSurface(holder.surface)
        ready = true
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        node.setPosition(0, 0, width, height)
        laidOut = false
        // A new or resized surface shows a frame at once, also while the frame loop is idle.
        draw()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        ready = false
        renderer.setSurface(null)
    }

    fun release() {
        ready = false
        renderer.destroy()
    }
}

@RequiresApi(33)
private fun RuntimeShader.setPortalLayout(width: Float, height: Float, diameter: Float, logoBounds: Rect, backdrop: PortalBackdrop, windowTop: Float) {
    setFloatUniform("uResolution", width, height)
    setFloatUniform("uLogoRect", logoBounds.left, logoBounds.top, logoBounds.width, logoBounds.height)
    setFloatUniform("uScale", minOf(width, height) * .43f / diameter)
    setFloatUniform("uPageTop", backdrop.top.red, backdrop.top.green, backdrop.top.blue)
    setFloatUniform("uPageBottom", backdrop.bottom.red, backdrop.bottom.green, backdrop.bottom.blue)
    setFloatUniform("uPage", windowTop, backdrop.endY)
}

@RequiresApi(33)
private fun RuntimeShader.setPortalFrame(frame: PortalFrame, packets: FloatArray, light: FloatArray) {
    setFloatUniform("uTilt", frame.tiltX, frame.tiltY)
    setFloatUniform("uTime", frame.time)
    setFloatUniform("uPower", frame.power)
    setFloatUniform("uBusy", frame.busy)
    setFloatUniform("uClose", frame.close)
    setFloatUniform("uImpact", frame.impact)
    setFloatUniform("uSplit", frame.split)
    setFloatUniform("uSpin", frame.spin)
    setFloatUniform("uSpinBlur", frame.spinBlur)
    setFloatUniform("uPress", frame.press)
    PortalTraffic.place(frame.time, packets)
    setFloatUniform("uPackets", packets)
    PortalLight.place(frame.time, frame.tiltX, frame.tiltY, light)
    setFloatUniform("uLight", light)
}

@RequiresApi(33)
private fun portalShader(source: String, logo: Bitmap): Shader = RuntimeShader(source).apply {
    val mask = BitmapShader(logo, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
    mask.setFilterMode(BitmapShader.FILTER_MODE_LINEAR)
    setInputShader("uLogoMask", mask)
    setInputShader("uNoise", BitmapShader(portalNoise(), Shader.TileMode.REPEAT, Shader.TileMode.REPEAT).apply {
        setFilterMode(BitmapShader.FILTER_MODE_LINEAR)
    })
}

@Composable
internal fun PortalEffect(phase: TunnelPhase, buttonDiameter: Dp, logoBounds: Rect, pressed: Boolean, backdrop: PortalBackdrop,
                          modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val resources = LocalResources.current
    val view = LocalView.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val diameter = with(LocalDensity.current) { buttonDiameter.toPx() }
    val logo = remember(resources) {
        createBitmap(256, 256).also { bitmap ->
            resources.getDrawable(R.drawable.ic_portal, null).mutate().apply {
                setBounds(0, 0, bitmap.width, bitmap.height)
                draw(android.graphics.Canvas(bitmap))
            }
        }
    }
    val logoImage = remember(logo) { logo.asImageBitmap() }
    val logoLayerPaint = remember { Paint() }
    // Typed as the API 1 Shader: a RuntimeShader cast here would run on Android 10-12 and fail to resolve the class.
    val shader: Shader? = remember(logo) {
        if (Build.VERSION.SDK_INT >= 33) portalShader(context.assets.open("portal.agsl").bufferedReader().use { it.readText() }, logo)
        else null
    }
    val packets = remember { FloatArray(24) }
    val light = remember { FloatArray(4) }
    val started = remember(phase) { SystemClock.uptimeMillis() }
    val connecting = phase == TunnelPhase.CONNECTING || phase == TunnelPhase.RECONNECTING
    val lit = phase == TunnelPhase.CONNECTED || connecting
    val targetPower = if (phase == TunnelPhase.CONNECTED) 1f else 0f
    val targetBusy = if (connecting) 1f else 0f
    val motion = remember { PortalMotion(lit, phase == TunnelPhase.CONNECTED) }
    val frame = remember { PortalFrame(targetPower, targetBusy) }
    var surface by remember { mutableStateOf<PortalSurface?>(null) }
    // Only the fallback Canvas below API 33 reads this, so a new frame redraws it.
    var tick by remember { mutableIntStateOf(0) }
    // The frame loop outlives recompositions, so it reads the finger through this.
    val pressedNow by rememberUpdatedState(pressed)
    // The sensor writes here and the frame loop picks it up, so tilt never triggers a redraw of its own.
    val liveTilt = remember { FloatArray(2) }
    var onScreen by remember { mutableStateOf(true) }

    var debugTilt by remember { mutableStateOf<Offset?>(null) }
    var debugSweepEnd by remember { mutableLongStateOf(0L) }

    fun redraw(vsyncNanos: Long = System.nanoTime()) {
        if (Build.VERSION.SDK_INT >= 33 && shader != null) surface?.draw(vsyncNanos) else tick++
    }

    LaunchedEffect(lifecycle, view) {
        val durationScale = coroutineContext[MotionDurationScale]
        val manager = context.getSystemService(SensorManager::class.java) ?: return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            snapshotFlow { durationScale?.scaleFactor ?: 1f }.collectLatest { factor ->
                liveTilt.fill(0f)
                if (factor <= 0f) return@collectLatest
                val sensor = manager.getDefaultSensor(Sensor.TYPE_GYROSCOPE) ?: return@collectLatest
                val tracker = TiltTracker()
                var previous = 0L
                var listening = true
                val listener = object : SensorEventListener {
                    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
                    override fun onSensorChanged(event: SensorEvent) {
                        if (!listening) return
                        val dt = if (previous == 0L) 0f else (event.timestamp - previous) / 1_000_000_000f
                        previous = event.timestamp
                        tracker.update(event.values[0], event.values[1], dt, view.display?.rotation ?: Surface.ROTATION_0)
                        liveTilt[0] = tracker.x; liveTilt[1] = tracker.y
                    }
                }
                if (manager.registerListener(listener, sensor, 16_666)) {
                    try { awaitCancellation() }
                    finally {
                        listening = false
                        manager.unregisterListener(listener)
                        liveTilt.fill(0f)
                    }
                }
            }
        }
    }

    LaunchedEffect(phase, lifecycle) {
        val durationScale = coroutineContext[MotionDurationScale]
        val transition = SystemClock.uptimeMillis()
        // Transitions are read from phase changes, so a STOPPING phase too short to render still closes the portal.
        if (motion.wasLit && !lit) {
            motion.closeAt = transition
            motion.holdPower = frame.power; motion.holdBusy = frame.busy
            motion.spinTarget = (round(frame.spin / HALF_TURN) - 1f) * HALF_TURN
        }
        if (lit) motion.closeAt = -1L
        if (phase == TunnelPhase.CONNECTED && !motion.wasConnected) {
            motion.impactAt = transition
            if (Build.VERSION.SDK_INT >= 30) view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        }
        motion.wasLit = lit
        motion.wasConnected = phase == TunnelPhase.CONNECTED
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            snapshotFlow { durationScale?.scaleFactor ?: 1f }.collectLatest { factor ->
                if (factor <= 0f) {
                    with(frame) {
                        time = 0f; age = 10f; power = targetPower; busy = targetBusy
                        close = 1f; impact = 10f; split = 0f; spin = 0f; spinBlur = 0f; tiltX = 0f; tiltY = 0f
                    }
                    motion.splitVelocity = 0f; motion.spinVelocity = 0f; motion.spinTarget = Float.NaN
                    // Without animation the press still shows, as a still frame for as long as the finger is down.
                    snapshotFlow { pressedNow }.collect {
                        frame.press = if (it) 1f else 0f
                        redraw()
                    }
                } else {
                    var previous = 0L
                    frame.animating = true
                    try {
                        do {
                            if (!onScreen) {
                                // Scrolled out of view: draw nothing until the button is back.
                                snapshotFlow { onScreen }.first { it }
                                previous = 0L
                            }
                            val now = awaitVsync()
                            // 60 fps: on a faster display every other vsync is skipped.
                            if (previous != 0L && now - previous < 15_000_000L) continue
                            run {
                                val clock = SystemClock.uptimeMillis()
                                val tilt = if (debugSweepEnd > clock) Offset(cos((debugSweepEnd - clock) * .00314f) * .85f, sin((debugSweepEnd - clock) * .00314f) * .85f)
                                    else debugTilt ?: Offset(liveTilt[0], liveTilt[1])
                                val targetPress = if (pressedNow) 1f else 0f
                                val dt = if (previous == 0L) 0f else ((now - previous) / 1_000_000_000f).coerceAtMost(.05f) / factor
                                previous = now
                                with(frame) {
                                    tiltX = tilt.x; tiltY = tilt.y
                                    // The ring gives quickly under the finger and springs back a little slower.
                                    press += (targetPress - press) * (1f - exp(-dt * if (pressedNow) 30f else 12f))
                                    if (abs(targetPress - press) < .001f) press = targetPress
                                    age = (clock - started) / 1000f / factor
                                    impact = if (motion.impactAt < 0L) 10f else ((clock - motion.impactAt) / 1000f / factor).coerceAtMost(10f)
                                    close = if (motion.closeAt < 0L) 1f else ((clock - motion.closeAt) / 1000f / factor / CLOSE_SECONDS).coerceAtMost(1f)
                                    val blend = 1f - exp(-dt * 7f)
                                    power += (targetPower - power) * blend
                                    busy += (targetBusy - busy) * blend
                                    if (!connecting && age >= 1.7f) {
                                        power = targetPower; busy = targetBusy
                                    }
                                    if (close < 1f) {
                                        val fade = 1f - smoothstep(.4f, 1f, close)
                                        power = maxOf(power, motion.holdPower * fade)
                                        busy = maxOf(busy, motion.holdBusy * fade)
                                    }
                                    motion.step(dt, connecting, close, if (phase == TunnelPhase.RECONNECTING) .75f else 1f)
                                    split = motion.split; spin = motion.spin; spinBlur = (motion.spinVelocity * .035f).coerceIn(-.06f, .06f)
                                    if (phase != TunnelPhase.STOPPING || age < 1.7f) {
                                        val speed = if (phase == TunnelPhase.RECONNECTING) .75f else 1f
                                        time += dt * (.28f + busy * .72f) * speed
                                    }
                                }
                                redraw(now)
                            }
                        } while (currentCoroutineContext().isActive && (phase != TunnelPhase.STOPPING || frame.age < 1.7f || frame.close < 1f))
                    } finally {
                        frame.animating = false
                    }
                }
            }
        }
    }

    if (BuildConfig.DEBUG) DisposableEffect(context) {
        // Debug builds can film tilt without moving the phone:
        // adb shell am broadcast -a app.wayveil.DEBUG_TILT --ef x .8 --ef y 0   (no extras releases it; --ef sweep 4 circles for 4 s)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                debugSweepEnd = if (intent.hasExtra("sweep")) SystemClock.uptimeMillis() + (intent.getFloatExtra("sweep", 0f) * 1000).toLong() else 0L
                debugTilt = if (intent.hasExtra("x") || intent.hasExtra("y")) Offset(intent.getFloatExtra("x", 0f), intent.getFloatExtra("y", 0f)) else null
            }
        }
        ContextCompat.registerReceiver(context, receiver, IntentFilter("app.wayveil.DEBUG_TILT"), ContextCompat.RECEIVER_EXPORTED)
        onDispose { context.unregisterReceiver(receiver) }
    }

    val placed = Modifier.onGloballyPositioned {
        onScreen = it.boundsInWindow().height > 0f
        val top = it.positionInWindow().y
        if (top != frame.windowTop) {
            frame.windowTop = top
            if (Build.VERSION.SDK_INT >= 33) surface?.relayout()
            if (!frame.animating) redraw()
        }
    }
    if (Build.VERSION.SDK_INT >= 33 && shader != null) {
        AndroidView(
            factory = { PortalSurface(it, shader as RuntimeShader).also { created -> surface = created } },
            modifier = modifier.then(placed),
            update = {
                it.layout = { shader, width, height -> shader.setPortalLayout(width, height, diameter, logoBounds, backdrop, frame.windowTop) }
                it.animate = { shader -> shader.setPortalFrame(frame, packets, light) }
                if (!frame.animating) it.draw()
            },
            onRelease = {
                it.release()
                surface = null
            },
        )
    } else Canvas(modifier.graphicsLayer().then(placed)) {
        tick
        val cyan = Color(0xFF84D5FF)
        val radius = diameter * (.588f - .014f * frame.press) / .43f / 2f
        val energy = .19f + frame.power * .71f + frame.busy * .65f + frame.press * .35f
        for (width in listOf(28f, 16f, 8f)) {
            drawCircle(cyan.copy(alpha = (.4f / width * energy).coerceAtMost(1f)), radius,
                style = Stroke(width.dp.toPx()))
        }
        drawCircle(Color(0xFF123A4D), radius, style = Stroke(8.dp.toPx()))
        rotate(frame.time * 40f + frame.tiltX * 50f - frame.tiltY * 35f) {
            drawCircle(Brush.sweepGradient(listOf(cyan.copy(alpha = .15f), cyan, Color(0xFF123A4D), cyan,
                cyan.copy(alpha = .15f)), center), radius, style = Stroke(4.dp.toPx()))
        }
        drawCircle(cyan.copy(alpha = (.2f + frame.power * .4f)), radius + 4.dp.toPx(), style = Stroke(.7.dp.toPx()))
        if (frame.busy > .01f) {
            val diameterSize = Size(radius * 2f, radius * 2f)
            drawArc(cyan.copy(alpha = frame.busy), -frame.time * 155f, 40f, false,
                center - Offset(radius, radius), diameterSize, style = Stroke(2.dp.toPx(), cap = StrokeCap.Round))
        }
        if (frame.impact < 1.5f) {
            drawCircle(cyan.copy(alpha = .4f * exp(-frame.impact * 3f)), radius + frame.impact * 30.dp.toPx(),
                style = Stroke(1.dp.toPx()))
        }
        if (!logoBounds.isEmpty) {
            drawContext.canvas.saveLayer(logoBounds, logoLayerPaint)
            drawImage(logoImage, dstOffset = IntOffset(logoBounds.left.roundToInt(), logoBounds.top.roundToInt()),
                dstSize = IntSize(logoBounds.width.roundToInt(), logoBounds.height.roundToInt()))
            val sweep = .5f + sin(frame.time * 1.1f + frame.tiltX * 1.4f - frame.tiltY * 1.1f) * .65f
            drawRect(Brush.linearGradient(listOf(Color(0xFF0B9FD5), cyan, Color(0xFFDFF6FF), cyan, Color(0xFF0B9FD5)),
                start = Offset(logoBounds.left + logoBounds.width * (sweep - .7f), logoBounds.top),
                end = Offset(logoBounds.left + logoBounds.width * (sweep + .7f), logoBounds.bottom)),
                topLeft = logoBounds.topLeft, size = logoBounds.size, blendMode = BlendMode.SrcIn)
            drawContext.canvas.restore()
        }
    }
}
