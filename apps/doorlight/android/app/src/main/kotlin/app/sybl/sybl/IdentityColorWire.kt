package app.sybl.sybl

internal object IdentityColorWire {
    private val colors = mapOf(
        "amber" to 0xFFF2B775.toInt(),
        "coral" to 0xFFF08A6C.toInt(),
        "rose" to 0xFFD97A9A.toInt(),
        "violet" to 0xFFA98BD4.toInt(),
        "sky" to 0xFF7FAFD8.toInt(),
        "teal" to 0xFF67BEB6.toInt(),
        "sage" to 0xFF8FBE83.toInt(),
        "lime" to 0xFFB5C96A.toInt(),
        "red" to 0xFFE86B69.toInt(),
        "orange" to 0xFFEF9D5D.toInt(),
        "yellow" to 0xFFE6CA63.toInt(),
        "green" to 0xFF6ACB7A.toInt(),
        "emerald" to 0xFF49AF84.toInt(),
        "mint" to 0xFF73D1B1.toInt(),
        "cyan" to 0xFF58C7D7.toInt(),
        "ice" to 0xFF9DCFE7.toInt(),
        "azure" to 0xFF559CE0.toInt(),
        "blue" to 0xFF6386E5.toInt(),
        "cobalt" to 0xFF5570C5.toInt(),
        "navy" to 0xFF526994.toInt(),
        "indigo" to 0xFF8277CD.toInt(),
        "magenta" to 0xFFC975BD.toInt(),
        "slate" to 0xFF98A4B7.toInt(),
        "ivory" to 0xFFE3DDC9.toInt(),
    )

    fun valid(value: String): Boolean = colors.containsKey(value)

    fun argb(value: String): Int? = colors[value]
}
