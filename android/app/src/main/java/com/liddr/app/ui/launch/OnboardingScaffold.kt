package com.liddr.app.ui.launch

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.liddr.app.R
import kotlinx.coroutines.delay

/* ── Background ────────────────────────────────────────────── */

@Composable
fun OnboardingBackground(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    val colors = MaterialTheme.colorScheme
    val t = rememberInfiniteTransition(label = "bg")
    val pulse by
            t.animateFloat(
                    initialValue = 0.93f,
                    targetValue = 1.07f,
                    animationSpec =
                            infiniteRepeatable(
                                    tween(3400, easing = FastOutSlowInEasing),
                                    RepeatMode.Reverse
                            ),
                    label = "pulse"
            )

    Box(
            modifier.fillMaxSize()
                    .background(Brush.verticalGradient(listOf(colors.background, colors.surface)))
    ) {
        Box(
                Modifier.align(Alignment.TopEnd)
                        .offset(x = 72.dp, y = (-56).dp)
                        .size(220.dp)
                        .graphicsLayer {
                            scaleX = pulse
                            scaleY = pulse
                        }
                        .clip(CircleShape)
                        .background(colors.primary.copy(alpha = 0.08f))
        )
        Box(
                Modifier.align(Alignment.BottomStart)
                        .offset(x = (-80).dp, y = 80.dp)
                        .size(260.dp)
                        .graphicsLayer {
                            val s = pulse * 1.04f
                            scaleX = s
                            scaleY = s
                        }
                        .clip(CircleShape)
                        .background(colors.tertiary.copy(alpha = 0.06f))
        )
        content()
    }
}

/* ── Logo ──────────────────────────────────────────────────── */

@Composable
fun LiddrLogo(modifier: Modifier = Modifier) {
    Image(
            painterResource(R.drawable.liddr_orange_logo),
            "Liddr",
            contentScale = ContentScale.Fit,
            modifier = modifier.fillMaxWidth(0.44f).height(52.dp)
    )
}

/* ── Legal footer ──────────────────────────────────────────── */

@Composable
fun LegalFooter(modifier: Modifier = Modifier) {
    Text(
            "By continuing you agree to Liddr\u2019s Terms & Privacy Policy.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = modifier.fillMaxWidth()
    )
}

/* ── Pill segmented control ────────────────────────────────── */

@Composable
fun PillSegmentedControl(
        selectedIndex: Int,
        labels: List<String>,
        modifier: Modifier = Modifier,
        onSelect: (Int) -> Unit
) {
    val colors = MaterialTheme.colorScheme
    val frac = 1f / labels.size
    val anim by
            animateFloatAsState(
                    selectedIndex * frac,
                    tween(280, easing = FastOutSlowInEasing),
                    label = "pill"
            )

    Box(
            modifier.fillMaxWidth()
                    .height(46.dp)
                    .clip(RoundedCornerShape(23.dp))
                    .background(colors.surfaceVariant)
    ) {
        Box(
                Modifier.fillMaxWidth(frac)
                        .fillMaxHeight()
                        .graphicsLayer { translationX = anim * size.width * labels.size }
                        .padding(3.dp)
                        .clip(RoundedCornerShape(20.dp))
                        .background(colors.primary)
        )
        Row(Modifier.fillMaxSize()) {
            labels.forEachIndexed { i, label ->
                val tc by
                        animateColorAsState(
                                if (i == selectedIndex) colors.onPrimary
                                else colors.onSurfaceVariant,
                                tween(200),
                                label = "seg$i"
                        )
                Box(
                        Modifier.weight(1f).fillMaxHeight().clickable(
                                        remember { MutableInteractionSource() },
                                        indication = null
                                ) { onSelect(i) },
                        contentAlignment = Alignment.Center
                ) {
                    Text(
                            label,
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.SemiBold,
                            color = tc
                    )
                }
            }
        }
    }
}

/* ── "or" divider ──────────────────────────────────────────── */

@Composable
fun OrDivider(modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        HorizontalDivider(Modifier.weight(1f), color = MaterialTheme.colorScheme.outline)
        Text(
                "or",
                Modifier.padding(horizontal = 16.dp),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        HorizontalDivider(Modifier.weight(1f), color = MaterialTheme.colorScheme.outline)
    }
}

/* ── Staggered entrance helper ─────────────────────────────── */

@Composable
fun rememberStaggeredEntrance(
        count: Int,
        initialDelayMs: Long = 80L,
        staggerMs: Long = 70L
): List<Boolean> {
    val flags = remember { mutableStateListOf(*Array(count) { false }) }

    // React to size changes: grow or shrink the list to match count.
    LaunchedEffect(count) {
        while (flags.size < count) flags.add(true)
        while (flags.size > count) flags.removeAt(flags.lastIndex)
    }

    // Initial staggered reveal on first composition only.
    LaunchedEffect(Unit) {
        delay(initialDelayMs)
        for (i in 0 until count) {
            if (i < flags.size) flags[i] = true
            if (i < count - 1) delay(staggerMs)
        }
    }
    return flags
}
