package com.liddr.app.ui.driver

import com.liddr.app.data.Requirement
import com.liddr.app.data.VerificationDocument
import java.text.ParseException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

// How "Your documents" reads the API's verification list: what stage each
// document is at, which ones need the driver, the order to show them in, and
// the summary at the top. Plain Kotlin, tested on the JVM.

/** Where one document stands. [label] is the two words shown in its status mark. */
enum class DocumentStage(val label: String, val needsDriver: Boolean = false) {
    MISSING("Not sent", needsDriver = true),
    UPLOADING("Sending"),

    /** The server is scanning the file before staff see it. */
    CHECKING("Checking"),
    IN_REVIEW("In review"),
    APPROVED("Approved"),
    REJECTED("Rejected", needsDriver = true),
    SEND_AGAIN("Send again", needsDriver = true),
    EXPIRED("Expired", needsDriver = true),
    ;

    /** Staff or the calendar turned this one down, as opposed to it never being sent. */
    val isProblem: Boolean get() = needsDriver && this != MISSING

    /** The colour its mark is drawn in. */
    val tone: StatusTone get() = when (this) {
        MISSING -> StatusTone.IDLE
        UPLOADING, CHECKING, IN_REVIEW -> StatusTone.WAITING
        APPROVED -> StatusTone.DONE
        REJECTED, SEND_AGAIN, EXPIRED -> StatusTone.PROBLEM
    }
}

/** What a colour says about a document: done, with Liddr, needs the driver, or not started. */
enum class StatusTone { DONE, WAITING, PROBLEM, IDLE }

/** The stage of [requirement]. [uploading] is true while this phone is sending its file. */
fun documentStage(requirement: Requirement, uploading: Boolean): DocumentStage = when {
    uploading -> DocumentStage.UPLOADING
    else -> when (requirement.document?.status) {
        null -> DocumentStage.MISSING
        "scanning" -> DocumentStage.CHECKING
        "validated" -> DocumentStage.APPROVED
        "rejected" -> DocumentStage.REJECTED
        "resubmission_required" -> DocumentStage.SEND_AGAIN
        "expired" -> DocumentStage.EXPIRED
        // "pending_review", and anything the API adds later: it has been sent, so it waits.
        else -> DocumentStage.IN_REVIEW
    }
}

/** One document as the screen shows it. [note] is what the driver must know to fix it. */
data class DocumentRow(val requirement: Requirement, val stage: DocumentStage, val note: String?)

/** The sections of the list, in the order they are shown. */
enum class DocumentGroup(val title: String) {
    TO_DO("To do"),
    WITH_LIDDR("With Liddr"),
    APPROVED("Approved"),
    OPTIONAL("Optional"),
}

/** Every requirement with its stage. [uploading] is the document type being sent, if any. */
fun documentRows(requirements: List<Requirement>, uploading: String?): List<DocumentRow> = requirements.map { requirement ->
    val stage = documentStage(requirement, uploading == requirement.documentType)
    val note = when {
        stage == DocumentStage.EXPIRED -> "This one has expired. Send the current one."
        stage.isProblem -> requirement.document?.rejectionReason?.trim()?.takeIf { it.isNotEmpty() } ?: "Please send a clearer copy."
        else -> null
    }
    DocumentRow(requirement, stage, note)
}

private fun groupOf(row: DocumentRow): DocumentGroup = when (row.stage) {
    DocumentStage.MISSING -> if (row.requirement.required) DocumentGroup.TO_DO else DocumentGroup.OPTIONAL
    DocumentStage.REJECTED, DocumentStage.SEND_AGAIN, DocumentStage.EXPIRED -> DocumentGroup.TO_DO
    DocumentStage.UPLOADING, DocumentStage.CHECKING, DocumentStage.IN_REVIEW -> DocumentGroup.WITH_LIDDR
    DocumentStage.APPROVED -> DocumentGroup.APPROVED
}

// Within a section: problems before what was never sent, and the nearest to done last.
private fun rank(stage: DocumentStage): Int = when (stage) {
    DocumentStage.REJECTED, DocumentStage.SEND_AGAIN, DocumentStage.EXPIRED -> 0
    DocumentStage.MISSING -> 1
    DocumentStage.UPLOADING -> 2
    DocumentStage.CHECKING -> 3
    DocumentStage.IN_REVIEW -> 4
    DocumentStage.APPROVED -> 5
}

/**
 * The rows in sections, what needs the driver first. Empty sections are left
 * out, and rows keep the API's order within the same rank.
 */
fun documentGroups(rows: List<DocumentRow>): List<Pair<DocumentGroup, List<DocumentRow>>> =
    DocumentGroup.entries.mapNotNull { group ->
        rows.filter { groupOf(it) == group }.sortedBy { rank(it.stage) }.takeIf { it.isNotEmpty() }?.let { group to it }
    }

/** What the summary is mostly saying, which picks its colour and icon. */
enum class SummaryTone { TO_FIX, TO_SEND, WAITING, DONE }

/**
 * Where the driver stands across every document that counts: the required
 * ones, and any optional one they chose to send.
 */
data class DocumentSummary(
    val total: Int,
    val approved: Int,
    /** Sent and not yet decided: sending, being checked, or in review. */
    val waiting: Int,
    val toFix: Int,
    val toSend: Int,
    val tone: SummaryTone,
    val headline: String,
    val detail: String,
)

fun summarise(rows: List<DocumentRow>): DocumentSummary {
    val counted = rows.filter { groupOf(it) != DocumentGroup.OPTIONAL }
    val approved = counted.count { it.stage == DocumentStage.APPROVED }
    val toFix = counted.count { it.stage.isProblem }
    val toSend = counted.count { it.stage == DocumentStage.MISSING }
    val waiting = counted.size - approved - toFix - toSend
    val (tone, headline, detail) = when {
        toFix > 0 -> Triple(SummaryTone.TO_FIX, "$toFix ${documents(toFix)} to fix", "Read the note under each one, then send it again.")
        toSend == counted.size -> Triple(SummaryTone.TO_SEND, "Send your $toSend ${documents(toSend)}", "Take a clear photo of each one. Our team checks every document by hand.")
        toSend > 0 -> Triple(SummaryTone.TO_SEND, "$toSend more to send", "Our team checks every document by hand once you send it.")
        waiting > 0 -> Triple(SummaryTone.WAITING, "Everything is in", "There is nothing more to do for now. We'll let you know as soon as your documents are reviewed.")
        else -> Triple(SummaryTone.DONE, "All documents approved", "There is nothing more to send. We're finishing your application.")
    }
    return DocumentSummary(counted.size, approved, waiting, toFix, toSend, tone, headline, detail)
}

private fun documents(count: Int) = if (count == 1) "document" else "documents"

/** What the drawer says about a sent document, as label and value pairs. */
fun documentFacts(document: VerificationDocument, locale: Locale = Locale.getDefault(), zone: TimeZone = TimeZone.getDefault()): List<Pair<String, String>> {
    val day = { at: Date, inZone: TimeZone -> SimpleDateFormat("d MMM yyyy", locale).apply { timeZone = inZone }.format(at) }
    val utc = TimeZone.getTimeZone("UTC")
    return listOfNotNull(
        document.createdAt?.let(::parseInstant)?.let { "Sent" to day(it, zone) },
        // An expiry is a calendar date, not a moment, so it is read and shown without a time zone shift.
        document.expiresOn?.let { parseOrNull("yyyy-MM-dd", it, utc) }?.let { "Expires" to day(it, utc) },
        document.version?.takeIf { it > 1 }?.let { "Version" to "$it" },
    )
}

private fun parseInstant(rfc3339: String): Date? =
    // SimpleDateFormat reads milliseconds at most, so any fraction is dropped first.
    parseOrNull("yyyy-MM-dd'T'HH:mm:ssXXX", rfc3339.replace(Regex("""\.\d+"""), ""), TimeZone.getTimeZone("UTC"))

private fun parseOrNull(pattern: String, text: String, zone: TimeZone): Date? = try {
    SimpleDateFormat(pattern, Locale.US).apply { timeZone = zone; isLenient = false }.parse(text)
} catch (_: ParseException) {
    null
}

/** Whether a fetched file is a PDF rather than a photo, by its first bytes. */
fun isPdf(bytes: ByteArray): Boolean = bytes.size >= PDF_MAGIC.size && PDF_MAGIC.indices.all { bytes[it] == PDF_MAGIC[it] }

private val PDF_MAGIC = "%PDF-".toByteArray(Charsets.US_ASCII)
