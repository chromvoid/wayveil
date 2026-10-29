package app.wayveil

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.tan
import org.junit.Assert.*
import org.junit.Test

class PortalTrafficTest {
    @Test
    fun trafficRunsBothWaysRoundTheRing() {
        val before = FloatArray(24).also { PortalTraffic.place(1f, it) }
        val after = FloatArray(24).also { PortalTraffic.place(1.01f, it) }
        // Positive when packet i's head moves counter-clockwise.
        fun swing(i: Int) = before[i * 4] * after[i * 4 + 1] - before[i * 4 + 1] * after[i * 4]
        assertEquals(1f, hypot(before[0], before[1]), 1e-5f)
        assertTrue(swing(0) > 0f)
        assertTrue(swing(2) > 0f)
        assertTrue(swing(3) < 0f)
        assertTrue(swing(5) < 0f)
    }

    @Test
    fun lightCirclesAtRest() {
        val light = FloatArray(4).also { PortalLight.place(2f, 0f, 0f, it) }
        assertEquals(1f, kotlin.math.sqrt(light[0] * light[0] + light[1] * light[1] + light[2] * light[2]), 1e-5f)
        assertEquals(0f, light[3], 0f)
        assertEquals(tan(1.3f), light[1] / light[0], 1e-4f)
    }

    @Test
    fun tiltDrawsTheLightToTheEdgeTurnedToTheViewer() {
        // The right edge turned away, so the left edge faces the viewer.
        val light = FloatArray(4).also { PortalLight.place(2f, .6f, 0f, it) }
        assertEquals(1f, light[3], 0f)
        assertTrue(light[0] < -.5f)
        assertTrue(abs(light[1]) < .25f)
    }
}
