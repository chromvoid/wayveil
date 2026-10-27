package app.wayveil

import org.junit.Assert.*
import org.junit.Test

class TiltTrackerTest {
    private fun TiltTracker.turn(rateX: Float, rateY: Float, seconds: Float, quarterTurns: Int = 0) =
        repeat((seconds * 100).toInt()) { update(rateX, rateY, .01f, quarterTurns) }

    @Test fun staysNeutralWithoutRotation() {
        val tracker = TiltTracker()
        tracker.turn(0f, 0f, 1f)
        assertEquals(0f, tracker.x, 0f)
        assertEquals(0f, tracker.y, 0f)
    }

    @Test fun turningTheRightEdgeAwayTiltsRight() {
        val tracker = TiltTracker()
        tracker.turn(0f, .3f, .5f)
        assertTrue(tracker.x > .35f)
        assertEquals(0f, tracker.y, 1e-6f)
    }

    @Test fun turningTheTopEdgeAwayTiltsUp() {
        val tracker = TiltTracker()
        tracker.turn(-.3f, 0f, .5f)
        assertTrue(tracker.y > .35f)
        assertEquals(0f, tracker.x, 1e-6f)
    }

    @Test fun reachesMostOfTheRangeAtSeventeenDegrees() {
        val tracker = TiltTracker()
        tracker.turn(0f, 1.5f, .2f)
        assertTrue(tracker.x > .7f)
        assertTrue(tracker.x < 1f)
    }

    @Test fun recentresWhileThePhoneRests() {
        val tracker = TiltTracker()
        tracker.turn(0f, 1.5f, .2f)
        tracker.turn(0f, 0f, 8f)
        assertTrue(tracker.x < .05f)
    }

    @Test fun mapsDeviceAxesToTheRotatedScreen() {
        // Turned counter-clockwise, the device's right edge becomes the top of the screen.
        val tracker = TiltTracker()
        tracker.turn(0f, .3f, .5f, quarterTurns = 1)
        assertTrue(tracker.y > .35f)
        assertEquals(0f, tracker.x, 1e-6f)
    }

    @Test fun ignoresGapsInTheSensorStream() {
        val tracker = TiltTracker()
        tracker.update(0f, 3f, 1f, 0)
        assertEquals(0f, tracker.x, 0f)
    }
}
