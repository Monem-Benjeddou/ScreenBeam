package com.screenbeam.app

/** macOS virtual key codes (Carbon kVK_*). Games running under Wine/CrossOver map these to PC scancodes. */
object MacKeys {
    const val A = 0x00; const val S = 0x01; const val D = 0x02; const val F = 0x03; const val H = 0x04
    const val G = 0x05; const val Z = 0x06; const val X = 0x07; const val C = 0x08; const val V = 0x09
    const val B = 0x0B; const val Q = 0x0C; const val W = 0x0D; const val E = 0x0E; const val R = 0x0F
    const val Y = 0x10; const val T = 0x11; const val O = 0x1F; const val U = 0x20; const val I = 0x22
    const val P = 0x23; const val L = 0x25; const val J = 0x26; const val K = 0x28; const val N = 0x2D
    const val M = 0x2E

    const val N1 = 0x12; const val N2 = 0x13; const val N3 = 0x14; const val N4 = 0x15; const val N5 = 0x17
    const val N6 = 0x16; const val N7 = 0x1A; const val N8 = 0x1C; const val N9 = 0x19; const val N0 = 0x1D

    const val EQUAL = 0x18; const val MINUS = 0x1B; const val RIGHT_BRACKET = 0x1E; const val LEFT_BRACKET = 0x21
    const val QUOTE = 0x27; const val SEMICOLON = 0x29; const val BACKSLASH = 0x2A; const val COMMA = 0x2B
    const val SLASH = 0x2C; const val PERIOD = 0x2F; const val GRAVE = 0x32

    const val RETURN = 0x24; const val TAB = 0x30; const val SPACE = 0x31; const val DELETE = 0x33
    const val ESCAPE = 0x35; const val FORWARD_DELETE = 0x75
    const val COMMAND = 0x37; const val SHIFT = 0x38; const val CAPS_LOCK = 0x39; const val OPTION = 0x3A
    const val CONTROL = 0x3B; const val RIGHT_SHIFT = 0x3C

    const val HOME = 0x73; const val END = 0x77; const val PAGE_UP = 0x74; const val PAGE_DOWN = 0x79
    const val LEFT = 0x7B; const val RIGHT = 0x7C; const val DOWN = 0x7D; const val UP = 0x7E

    val F_KEYS = intArrayOf(0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F) // F1..F12

    const val KP0 = 0x52; const val KP1 = 0x53; const val KP2 = 0x54; const val KP3 = 0x55; const val KP4 = 0x56
    const val KP5 = 0x57; const val KP6 = 0x58; const val KP7 = 0x59; const val KP8 = 0x5B; const val KP9 = 0x5C
    const val KP_DECIMAL = 0x41; const val KP_MULTIPLY = 0x43; const val KP_PLUS = 0x45; const val KP_DIVIDE = 0x4B
    const val KP_ENTER = 0x4C; const val KP_MINUS = 0x4E

    val MODIFIERS = setOf(COMMAND, SHIFT, OPTION, CONTROL, RIGHT_SHIFT)
}
