package app.wayveil

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.SystemClock
import android.view.Surface
import androidx.annotation.Keep
import androidx.annotation.RequiresApi
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.core.graphics.createBitmap
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.isActive
import kotlin.coroutines.coroutineContext
import kotlin.math.exp
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.roundToInt

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
    val shader: Shader? = remember(logo) {
        if (Build.VERSION.SDK_INT >= 33) PortalShaderApi33.create(
            context.assets.open("portal.agsl").bufferedReader().use { it.readText() }, logo)
        else null
    }
    val brush = remember(shader) {
        if (Build.VERSION.SDK_INT >= 33 && shader != null) ShaderBrush(shader) else null
    }
    val started = remember(phase) { SystemClock.uptimeMillis() }
    val connecting = phase == TunnelPhase.CONNECTING || phase == TunnelPhase.RECONNECTING
    val targetPower = if (phase == TunnelPhase.CONNECTED) 1f else 0f
    val targetBusy = if (connecting) 1f else 0f
    var time by remember { mutableFloatStateOf(0f) }
    var age by remember { mutableFloatStateOf(10f) }
    var power by remember { mutableFloatStateOf(targetPower) }
    var busy by remember { mutableFloatStateOf(targetBusy) }
    var tiltX by remember { mutableFloatStateOf(0f) }
    var tiltY by remember { mutableFloatStateOf(0f) }

    LaunchedEffect(lifecycle, view) {
        val durationScale = coroutineContext[MotionDurationScale]
        val manager = context.getSystemService(SensorManager::class.java) ?: return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            snapshotFlow { durationScale?.scaleFactor ?: 1f }.collectLatest { factor ->
                tiltX = 0f; tiltY = 0f
                if (factor <= 0f) return@collectLatest
                val sensor = manager.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR) ?: return@collectLatest
                val rotation = FloatArray(9)
                var light: FloatArray? = null
                var displayRotation = -1
                var previous = 0L
                var listening = true
                val listener = object : SensorEventListener {
                    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
                    override fun onSensorChanged(event: SensorEvent) {
                        if (!listening || event.timestamp - previous < 16_000_000L) return
                        previous = event.timestamp
                        SensorManager.getRotationMatrixFromVector(rotation, event.values)
                        val orientation = view.display?.rotation ?: Surface.ROTATION_0
                        if (light == null || orientation != displayRotation) {
                            val base = when (orientation) {
                                Surface.ROTATION_90 -> Offset(-.55f, -.35f)
                                Surface.ROTATION_180 -> Offset(.35f, -.55f)
                                Surface.ROTATION_270 -> Offset(.55f, .35f)
                                else -> Offset(-.35f, .55f)
                            }
                            light = floatArrayOf(
                                rotation[0] * base.x + rotation[1] * base.y + rotation[2] * .9f,
                                rotation[3] * base.x + rotation[4] * base.y + rotation[5] * .9f,
                                rotation[6] * base.x + rotation[7] * base.y + rotation[8] * .9f)
                            displayRotation = orientation
                        }
                        val source = light ?: return
                        // Keep the light fixed in the initial reference frame as the phone turns around any axis.
                        val x = rotation[0] * source[0] + rotation[3] * source[1] + rotation[6] * source[2]
                        val y = rotation[1] * source[0] + rotation[4] * source[1] + rotation[7] * source[2]
                        val screen = when (orientation) {
                            Surface.ROTATION_90 -> Offset(y, -x)
                            Surface.ROTATION_180 -> Offset(-x, -y)
                            Surface.ROTATION_270 -> Offset(-y, x)
                            else -> Offset(x, y)
                        }
                        val nextX = tiltX + (((screen.x + .35f) * 1.6f).coerceIn(-1f, 1f) - tiltX) * .0835f
                        val nextY = tiltY + (((screen.y - .55f) * 1.6f).coerceIn(-1f, 1f) - tiltY) * .0835f
                        if (abs(nextX - tiltX) > .001f) tiltX = nextX
                        if (abs(nextY - tiltY) > .001f) tiltY = nextY
                    }
                }
                if (manager.registerListener(listener, sensor, 16_666)) {
                    try { awaitCancellation() }
                    finally {
                        listening = false
                        manager.unregisterListener(listener)
                        tiltX = 0f; tiltY = 0f
                    }
                }
            }
        }
    }

    LaunchedEffect(phase, lifecycle) {
        val durationScale = coroutineContext[MotionDurationScale]
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            snapshotFlow { durationScale?.scaleFactor ?: 1f }.collectLatest { factor ->
                if (factor <= 0f) {
                    time = 0f; age = 10f; power = targetPower; busy = targetBusy
                } else {
                    var previous = 0L
                    do {
                        withFrameNanos { now ->
                            if (previous != 0L && now - previous < 16_000_000L) return@withFrameNanos
                            val dt = if (previous == 0L) 0f else ((now - previous) / 1_000_000_000f).coerceAtMost(.05f) / factor
                            previous = now
                            age = (SystemClock.uptimeMillis() - started) / 1000f / factor
                            val blend = 1f - exp(-dt * 7f)
                            power += (targetPower - power) * blend
                            busy += (targetBusy - busy) * blend
                            if (!connecting && age >= 1.7f) {
                                power = targetPower; busy = targetBusy
                            }
                            if (phase != TunnelPhase.STOPPING || age < 1.7f) {
                                val speed = if (phase == TunnelPhase.RECONNECTING) .75f else 1f
                                time += dt * (.28f + busy * .72f) * speed
                            }
                        }
                    } while (currentCoroutineContext().isActive && (phase != TunnelPhase.STOPPING || age < 1.7f))
                }
            }
        }
    }

    Canvas(modifier) {
        if (Build.VERSION.SDK_INT >= 33 && shader != null && brush != null) {
            PortalShaderApi33.update(shader, size, logoBounds, diameter, tiltX, tiltY, time, power, busy, age, when (phase) {
                TunnelPhase.CONNECTED -> 2f
                TunnelPhase.STOPPING -> 3f
                else -> if (connecting) 1f else 0f
            })
            drawRect(brush)
        } else {
            val mint = Color(0xFFB6F0C8)
            val radius = diameter * .588f / .43f / 2f
            val energy = .19f + power * .71f + busy * .65f
            val face = if (phase == TunnelPhase.CONNECTED)
                listOf(Color(0xFF355F52), Color(0xFF163A36), Color(0xFF102B30))
                else listOf(Color(0xFF294C4A), Color(0xFF122D31), Color(0xFF0D2229))
            val light = center + Offset(
                diameter * (-.18f + sin(time * .6f) * .12f + tiltX * .25f),
                diameter * (-.34f + (cos(time * .55f) - 1f) * .08f - tiltY * .25f))
            drawCircle(Brush.radialGradient(face, light, diameter * .85f), diameter / 2f)
            for (width in listOf(28f, 16f, 8f)) {
                drawCircle(mint.copy(alpha = (.4f / width * energy).coerceAtMost(1f)), radius,
                    style = Stroke(width.dp.toPx()))
            }
            drawCircle(Color(0xFF254A49), radius, style = Stroke(8.dp.toPx()))
            rotate(time * 40f + tiltX * 50f - tiltY * 35f) {
                drawCircle(Brush.sweepGradient(listOf(mint.copy(alpha = .15f), mint, Color(0xFF254A49), mint,
                    mint.copy(alpha = .15f)), center), radius, style = Stroke(4.dp.toPx()))
            }
            drawCircle(mint.copy(alpha = (.2f + power * .4f)), radius + 4.dp.toPx(), style = Stroke(.7.dp.toPx()))
            if (busy > .01f) {
                val diameterSize = Size(radius * 2f, radius * 2f)
                drawArc(mint.copy(alpha = busy), -time * 155f, 40f, false,
                    center - Offset(radius, radius), diameterSize, style = Stroke(2.dp.toPx(), cap = StrokeCap.Round))
            }
            if (phase == TunnelPhase.CONNECTED && age < 1.5f) {
                drawCircle(mint.copy(alpha = .4f * exp(-age * 3f)), radius + age * 30.dp.toPx(),
                    style = Stroke(1.dp.toPx()))
            }
            if (!logoBounds.isEmpty) {
                drawContext.canvas.saveLayer(logoBounds, logoLayerPaint)
                drawImage(logoImage, dstOffset = IntOffset(logoBounds.left.roundToInt(), logoBounds.top.roundToInt()),
                    dstSize = IntSize(logoBounds.width.roundToInt(), logoBounds.height.roundToInt()))
                val sweep = .5f + sin(time * 1.1f + tiltX * 1.4f - tiltY * 1.1f) * .65f
                drawRect(Brush.linearGradient(listOf(Color(0xFF4A8F7E), mint, Color(0xFFE0FFF0), mint, Color(0xFF4A8F7E)),
                    start = Offset(logoBounds.left + logoBounds.width * (sweep - .7f), logoBounds.top),
                    end = Offset(logoBounds.left + logoBounds.width * (sweep + .7f), logoBounds.bottom)),
                    topLeft = logoBounds.topLeft, size = logoBounds.size, blendMode = BlendMode.SrcIn)
                drawContext.canvas.restore()
            }
        }
    }
}

// Preserve the API boundary when R8 optimizes Compose lambdas used on older Android.
@Keep
@RequiresApi(33)
private object PortalShaderApi33 {
    fun create(source: String, logo: Bitmap): Shader = RuntimeShader(source).apply {
        val mask = BitmapShader(logo, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        mask.setFilterMode(BitmapShader.FILTER_MODE_LINEAR)
        setInputShader("uLogoMask", mask)
    }

    fun update(shader: Shader, size: Size, logoBounds: Rect, diameter: Float, tiltX: Float, tiltY: Float,
               time: Float, power: Float, busy: Float, age: Float, phase: Float) {
        shader as RuntimeShader
        shader.setFloatUniform("uResolution", size.width, size.height)
        shader.setFloatUniform("uTilt", tiltX, tiltY)
        shader.setFloatUniform("uLogoRect", logoBounds.left, logoBounds.top, logoBounds.width, logoBounds.height)
        shader.setFloatUniform("uScale", size.minDimension * .43f / diameter)
        shader.setFloatUniform("uTime", time)
        shader.setFloatUniform("uPower", power)
        shader.setFloatUniform("uBusy", busy)
        shader.setFloatUniform("uAge", age)
        shader.setFloatUniform("uPhase", phase)
    }
}
