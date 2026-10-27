package app.wayveil

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.BitmapShader
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.SystemClock
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
import androidx.compose.ui.graphics.ShaderBrush
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlin.coroutines.coroutineContext
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.round
import kotlin.math.sin
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

@Composable
internal fun PortalEffect(phase: TunnelPhase, buttonDiameter: Dp, logoBounds: Rect, modifier: Modifier = Modifier) {
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
    val shader = remember(logo) {
        if (Build.VERSION.SDK_INT >= 33) RuntimeShader(context.assets.open("portal.agsl").bufferedReader().use { it.readText() }).apply {
            val mask = BitmapShader(logo, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
            mask.setFilterMode(BitmapShader.FILTER_MODE_LINEAR)
            setInputShader("uLogoMask", mask)
            setInputShader("uNoise", BitmapShader(portalNoise(), Shader.TileMode.REPEAT, Shader.TileMode.REPEAT).apply {
                setFilterMode(BitmapShader.FILTER_MODE_LINEAR)
            })
        }
        else null
    }
    val brush = remember(shader) {
        if (Build.VERSION.SDK_INT >= 33 && shader != null) ShaderBrush(shader) else null
    }
    val started = remember(phase) { SystemClock.uptimeMillis() }
    val connecting = phase == TunnelPhase.CONNECTING || phase == TunnelPhase.RECONNECTING
    val lit = phase == TunnelPhase.CONNECTED || connecting
    val targetPower = if (phase == TunnelPhase.CONNECTED) 1f else 0f
    val targetBusy = if (connecting) 1f else 0f
    val motion = remember { PortalMotion(lit, phase == TunnelPhase.CONNECTED) }
    var time by remember { mutableFloatStateOf(0f) }
    var age by remember { mutableFloatStateOf(10f) }
    var power by remember { mutableFloatStateOf(targetPower) }
    var busy by remember { mutableFloatStateOf(targetBusy) }
    var close by remember { mutableFloatStateOf(1f) }
    var impact by remember { mutableFloatStateOf(10f) }
    var split by remember { mutableFloatStateOf(0f) }
    var spin by remember { mutableFloatStateOf(0f) }
    var spinBlur by remember { mutableFloatStateOf(0f) }
    var tiltX by remember { mutableFloatStateOf(0f) }
    var tiltY by remember { mutableFloatStateOf(0f) }
    // The sensor writes here and the frame loop picks it up, so tilt never triggers a redraw of its own.
    val liveTilt = remember { FloatArray(2) }
    var onScreen by remember { mutableStateOf(true) }

    var debugTilt by remember { mutableStateOf<Offset?>(null) }
    var debugSweepEnd by remember { mutableLongStateOf(0L) }

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
            motion.holdPower = power; motion.holdBusy = busy
            motion.spinTarget = (round(spin / HALF_TURN) - 1f) * HALF_TURN
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
                    time = 0f; age = 10f; power = targetPower; busy = targetBusy
                    close = 1f; impact = 10f; split = 0f; spin = 0f; spinBlur = 0f; tiltX = 0f; tiltY = 0f
                    motion.splitVelocity = 0f; motion.spinVelocity = 0f; motion.spinTarget = Float.NaN
                } else {
                    var previous = 0L
                    var lively = true
                    do {
                        if (!onScreen) {
                            // Scrolled out of view: draw nothing until the button is back.
                            snapshotFlow { onScreen }.first { it }
                            previous = 0L
                        }
                        // Between slow frames, sleep instead of waking on every vsync just to skip it.
                        if (!lively) delay(20)
                        withFrameNanos { now ->
                            val clock = SystemClock.uptimeMillis()
                            val tilt = if (debugSweepEnd > clock) Offset(cos((debugSweepEnd - clock) * .00314f) * .85f, sin((debugSweepEnd - clock) * .00314f) * .85f)
                                else debugTilt ?: Offset(liveTilt[0], liveTilt[1])
                            // Quick motion runs at 60 fps; the slow idle drift looks the same at 30 and costs half.
                            lively = connecting || close < 1f || impact < 2f || abs(power - targetPower) > .002f || abs(busy - targetBusy) > .002f
                                || motion.splitVelocity != 0f || motion.spinVelocity != 0f || abs(tilt.x - tiltX) > .005f || abs(tilt.y - tiltY) > .005f
                            if (previous != 0L && now - previous < if (lively) 16_000_000L else 30_000_000L) return@withFrameNanos
                            val dt = if (previous == 0L) 0f else ((now - previous) / 1_000_000_000f).coerceAtMost(.05f) / factor
                            previous = now
                            tiltX = tilt.x; tiltY = tilt.y
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
                    } while (currentCoroutineContext().isActive && (phase != TunnelPhase.STOPPING || age < 1.7f || close < 1f))
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

    // Its own layer keeps the per-frame redraw from re-recording the rest of the screen.
    Canvas(modifier.graphicsLayer().onGloballyPositioned { onScreen = it.boundsInWindow().height > 0f }) {
        val tilt = Offset(tiltX, tiltY)
        if (Build.VERSION.SDK_INT >= 33 && shader != null && brush != null) {
            shader.setFloatUniform("uResolution", size.width, size.height)
            shader.setFloatUniform("uTilt", tilt.x, tilt.y)
            shader.setFloatUniform("uLogoRect", logoBounds.left, logoBounds.top, logoBounds.width, logoBounds.height)
            shader.setFloatUniform("uScale", size.minDimension * .43f / diameter)
            shader.setFloatUniform("uTime", time)
            shader.setFloatUniform("uPower", power)
            shader.setFloatUniform("uBusy", busy)
            shader.setFloatUniform("uClose", close)
            shader.setFloatUniform("uImpact", impact)
            shader.setFloatUniform("uSplit", split)
            shader.setFloatUniform("uSpin", spin)
            shader.setFloatUniform("uSpinBlur", spinBlur)
            drawRect(brush)
        } else {
            val mint = Color(0xFFB6F0C8)
            val radius = diameter * .588f / .43f / 2f
            val energy = .19f + power * .71f + busy * .65f
            val face = if (phase == TunnelPhase.CONNECTED)
                listOf(Color(0xFF355F52), Color(0xFF163A36), Color(0xFF102B30))
                else listOf(Color(0xFF294C4A), Color(0xFF122D31), Color(0xFF0D2229))
            val light = center + Offset(
                diameter * (-.18f + sin(time * .6f) * .12f - tilt.x * .25f),
                diameter * (-.34f + (cos(time * .55f) - 1f) * .08f + tilt.y * .25f))
            drawCircle(Brush.radialGradient(face, light, diameter * .85f), diameter / 2f)
            for (width in listOf(28f, 16f, 8f)) {
                drawCircle(mint.copy(alpha = (.4f / width * energy).coerceAtMost(1f)), radius,
                    style = Stroke(width.dp.toPx()))
            }
            drawCircle(Color(0xFF254A49), radius, style = Stroke(8.dp.toPx()))
            rotate(time * 40f + tilt.x * 50f - tilt.y * 35f) {
                drawCircle(Brush.sweepGradient(listOf(mint.copy(alpha = .15f), mint, Color(0xFF254A49), mint,
                    mint.copy(alpha = .15f)), center), radius, style = Stroke(4.dp.toPx()))
            }
            drawCircle(mint.copy(alpha = (.2f + power * .4f)), radius + 4.dp.toPx(), style = Stroke(.7.dp.toPx()))
            if (busy > .01f) {
                val diameterSize = Size(radius * 2f, radius * 2f)
                drawArc(mint.copy(alpha = busy), -time * 155f, 40f, false,
                    center - Offset(radius, radius), diameterSize, style = Stroke(2.dp.toPx(), cap = StrokeCap.Round))
            }
            if (impact < 1.5f) {
                drawCircle(mint.copy(alpha = .4f * exp(-impact * 3f)), radius + impact * 30.dp.toPx(),
                    style = Stroke(1.dp.toPx()))
            }
            if (!logoBounds.isEmpty) {
                drawContext.canvas.saveLayer(logoBounds, logoLayerPaint)
                drawImage(logoImage, dstOffset = IntOffset(logoBounds.left.roundToInt(), logoBounds.top.roundToInt()),
                    dstSize = IntSize(logoBounds.width.roundToInt(), logoBounds.height.roundToInt()))
                val sweep = .5f + sin(time * 1.1f + tilt.x * 1.4f - tilt.y * 1.1f) * .65f
                drawRect(Brush.linearGradient(listOf(Color(0xFF4A8F7E), mint, Color(0xFFE0FFF0), mint, Color(0xFF4A8F7E)),
                    start = Offset(logoBounds.left + logoBounds.width * (sweep - .7f), logoBounds.top),
                    end = Offset(logoBounds.left + logoBounds.width * (sweep + .7f), logoBounds.bottom)),
                    topLeft = logoBounds.topLeft, size = logoBounds.size, blendMode = BlendMode.SrcIn)
                drawContext.canvas.restore()
            }
        }
    }
}
