package app.wayveil

import kotlin.math.exp
import kotlin.math.tanh

/**
 * Turns gyroscope rates into a screen-space tilt that follows the hand and drifts back to neutral when it rests.
 *
 * x > 0 when the right edge of the screen turns away from the viewer, y > 0 when the top edge does.
 * Rates are rad/s about the device axes (x right, y up, z towards the viewer), as both Android and iOS report them.
 * The iOS port in PortalEffect.swift mirrors this class.
 */
internal class TiltTracker(private val fullScale: Float = .3f, private val recentreSeconds: Float = 2.5f) {
    private var pitch = 0f
    private var roll = 0f
    var x = 0f
        private set
    var y = 0f
        private set

    /** [quarterTurns] counts counter-clockwise quarter turns of the device from its natural orientation (Surface.ROTATION_*). */
    fun update(rateX: Float, rateY: Float, dt: Float, quarterTurns: Int) {
        if (dt <= 0f || dt > .25f) return
        val leak = exp(-dt / recentreSeconds)
        pitch = (pitch + rateX * dt) * leak
        roll = (roll + rateY * dt) * leak
        val deviceX = tanh(roll / fullScale)
        val deviceY = tanh(-pitch / fullScale)
        when (quarterTurns and 3) {
            1 -> { x = -deviceY; y = deviceX }
            2 -> { x = -deviceX; y = -deviceY }
            3 -> { x = deviceY; y = -deviceX }
            else -> { x = deviceX; y = deviceY }
        }
    }
}
