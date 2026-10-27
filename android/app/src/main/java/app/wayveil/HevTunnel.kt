package app.wayveil

object HevTunnel {
    init { System.loadLibrary("wayveilhev") }

    @JvmStatic external fun prepare()
    @JvmStatic external fun stats(): LongArray
    @JvmStatic external fun run(config: String, fd: Int): Int
    @JvmStatic external fun stop()
}
