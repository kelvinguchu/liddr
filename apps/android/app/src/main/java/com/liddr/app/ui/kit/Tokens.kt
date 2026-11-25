package com.liddr.app.ui.kit

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp

// The one set of measurements every screen uses. A size that isn't here does
// not belong in a screen: add it here with what it is for, or use one that is.
// SizeTokenTest fails the build on raw dp values in migrated screens.

/** Spacing on a 4dp grid. */
object Space {
    /** Title to its subtitle; icon to label inside a chip. */
    val xs = 4.dp

    /** Between sibling cards, chips and stacked rows. */
    val sm = 8.dp

    /** Icon to text in a row; a heading to its content; stacked buttons. */
    val md = 12.dp

    /** Screen gutter, card padding, header padding, bottom action inset. */
    val lg = 16.dp

    /** A screen's title block to its first content. */
    val xl = 24.dp

    /** One section to the next. */
    val xxl = 32.dp
}

/** Corner radii. A control nested in a card uses the card's radius minus its padding. */
object Radius {
    /** Chips, small plates. */
    val sm = 8.dp

    /** Controls nested in a card: segments, small buttons, thumbnails, code boxes. */
    val md = 12.dp

    /** Cards, panels, buttons, fields, the trip ticket. */
    val lg = 16.dp

    /** Sheets and dialogs. */
    val xl = 24.dp
}

/** Shapes for the radii above. */
object Corners {
    val sm = RoundedCornerShape(Radius.sm)
    val md = RoundedCornerShape(Radius.md)
    val lg = RoundedCornerShape(Radius.lg)
    val sheet = RoundedCornerShape(topStart = Radius.xl, topEnd = Radius.xl)
}

/** Component sizes. */
object Size {
    /** Primary and secondary buttons, fields. */
    val control = 56.dp

    /** A field with its label inside it. */
    val tallField = 64.dp

    /** The smallest touch target: link buttons, small buttons, circle buttons, avatars. */
    val touch = 48.dp

    /** The floating dock. */
    val dock = 56.dp

    /** A one-line list row. */
    val row = 56.dp

    /** A two-line list row. */
    val tallRow = 72.dp

    /** A text chip or a segment. */
    val chip = 40.dp

    /** Leading and action icons. */
    val icon = 24.dp

    /** Trailing icons, such as a row's chevron. */
    val smallIcon = 20.dp

    /** A vehicle illustration in a row. */
    val art = 44.dp
}

/** The screen gutter. */
val Gutter = Space.lg
