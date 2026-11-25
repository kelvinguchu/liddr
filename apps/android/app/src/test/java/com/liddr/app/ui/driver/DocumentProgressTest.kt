package com.liddr.app.ui.driver

import com.liddr.app.data.Requirement
import com.liddr.app.data.VerificationDocument
import org.junit.Assert.assertEquals
import org.junit.Test

class DocumentProgressTest {
    private fun requirement(type: String, status: String? = null, reason: String? = null, required: Boolean = true) =
        Requirement(type, type.uppercase(), required, requiresExpiry = false, document = status?.let { VerificationDocument(it, reason) })

    @Test
    fun readsEachStatus() {
        class Case(val name: String, val status: String?, val uploading: Boolean, val want: DocumentStage)
        val cases = listOf(
            Case("nothing sent", null, false, DocumentStage.MISSING),
            Case("sending the first copy", null, true, DocumentStage.UPLOADING),
            Case("the server's scan", "scanning", false, DocumentStage.CHECKING),
            Case("waiting for staff", "pending_review", false, DocumentStage.IN_REVIEW),
            Case("approved", "validated", false, DocumentStage.APPROVED),
            Case("rejected", "rejected", false, DocumentStage.REJECTED),
            Case("a clearer copy wanted", "resubmission_required", false, DocumentStage.SEND_AGAIN),
            Case("expired", "expired", false, DocumentStage.EXPIRED),
            Case("sending a replacement", "rejected", true, DocumentStage.UPLOADING),
            Case("a status added later counts as sent", "archived", false, DocumentStage.IN_REVIEW),
        )
        for (case in cases) assertEquals(case.name, case.want, documentStage(requirement("id", case.status), case.uploading))
    }

    @Test
    fun everyStageHasItsColour() {
        // Grey is only for what was never sent; everything the driver has done shows where it stands.
        val want = mapOf(
            DocumentStage.MISSING to StatusTone.IDLE,
            DocumentStage.UPLOADING to StatusTone.WAITING,
            DocumentStage.CHECKING to StatusTone.WAITING,
            DocumentStage.IN_REVIEW to StatusTone.WAITING,
            DocumentStage.APPROVED to StatusTone.DONE,
            DocumentStage.REJECTED to StatusTone.PROBLEM,
            DocumentStage.SEND_AGAIN to StatusTone.PROBLEM,
            DocumentStage.EXPIRED to StatusTone.PROBLEM,
        )
        assertEquals(want, DocumentStage.entries.associateWith { it.tone })
    }

    @Test
    fun onlyStagesTheDriverCanActOnOfferAnUpload() {
        val want = setOf(DocumentStage.MISSING, DocumentStage.REJECTED, DocumentStage.SEND_AGAIN, DocumentStage.EXPIRED)
        assertEquals(want, DocumentStage.entries.filter { it.needsDriver }.toSet())
    }

    @Test
    fun showsTheReviewersNote() {
        class Case(val name: String, val status: String?, val reason: String?, val want: String?)
        val cases = listOf(
            Case("a rejection with a reason", "rejected", "The photo is blurred", "The photo is blurred"),
            Case("a rejection without one", "rejected", null, "Please send a clearer copy."),
            Case("a blank reason", "resubmission_required", "  ", "Please send a clearer copy."),
            Case("expired", "expired", null, "This one has expired. Send the current one."),
            Case("an old reason on an approved document", "validated", "The photo is blurred", null),
            Case("not sent", null, null, null),
        )
        for (case in cases) assertEquals(case.name, case.want, documentRows(listOf(requirement("id", case.status, case.reason)), null).single().note)
    }

    @Test
    fun putsWhatNeedsTheDriverFirst() {
        val rows = documentRows(
            listOf(
                requirement("approved", "validated"),
                requirement("missing"),
                requirement("waiting", "pending_review"),
                requirement("rejected", "rejected"),
                requirement("extra", required = false),
                requirement("checking", "scanning"),
                requirement("expired", "expired"),
                requirement("sending"),
            ),
            uploading = "sending",
        )
        val got = documentGroups(rows).map { (group, members) -> group to members.map { it.requirement.documentType } }
        val want = listOf(
            DocumentGroup.TO_DO to listOf("rejected", "expired", "missing"),
            DocumentGroup.WITH_LIDDR to listOf("sending", "checking", "waiting"),
            DocumentGroup.APPROVED to listOf("approved"),
            DocumentGroup.OPTIONAL to listOf("extra"),
        )
        assertEquals(want, got)
    }

    @Test
    fun leavesOutEmptyGroups() {
        val rows = documentRows(listOf(requirement("a", "validated"), requirement("b", "validated")), null)
        assertEquals(listOf(DocumentGroup.APPROVED), documentGroups(rows).map { it.first })
    }

    @Test
    fun anOptionalDocumentCountsOnceItIsSent() {
        val rows = documentRows(listOf(requirement("extra", "rejected", required = false)), null)
        assertEquals(listOf(DocumentGroup.TO_DO), documentGroups(rows).map { it.first })
        assertEquals(1, summarise(rows).total)
    }

    @Test
    fun tellsTheDriverWhereTheyStand() {
        class Case(val name: String, val statuses: List<String?>, val counts: List<Int>, val tone: SummaryTone, val headline: String)
        val cases = listOf(
            Case("nothing sent yet", listOf(null, null, null), listOf(0, 0, 0, 3), SummaryTone.TO_SEND, "Send your 3 documents"),
            Case("part way", listOf("validated", "pending_review", null, null), listOf(1, 1, 0, 2), SummaryTone.TO_SEND, "2 more to send"),
            Case("one left", listOf("pending_review", null), listOf(0, 1, 0, 1), SummaryTone.TO_SEND, "1 more to send"),
            Case("a problem outranks what is missing", listOf("rejected", null, "validated"), listOf(1, 0, 1, 1), SummaryTone.TO_FIX, "1 document to fix"),
            Case("several problems", listOf("rejected", "expired", "resubmission_required"), listOf(0, 0, 3, 0), SummaryTone.TO_FIX, "3 documents to fix"),
            Case("all sent", listOf("validated", "pending_review", "scanning"), listOf(1, 2, 0, 0), SummaryTone.WAITING, "Everything is in"),
            Case("all approved", listOf("validated", "validated"), listOf(2, 0, 0, 0), SummaryTone.DONE, "All documents approved"),
        )
        for (case in cases) {
            val rows = documentRows(case.statuses.mapIndexed { index, status -> requirement("doc$index", status) }, null)
            val got = summarise(rows)
            assertEquals(case.name, case.counts, listOf(got.approved, got.waiting, got.toFix, got.toSend))
            assertEquals(case.name, case.statuses.size, got.total)
            assertEquals(case.name, case.tone, got.tone)
            assertEquals(case.name, case.headline, got.headline)
        }
    }

    @Test
    fun anUploadInFlightCountsAsWaiting() {
        val got = summarise(documentRows(listOf(requirement("a"), requirement("b")), uploading = "a"))
        assertEquals(listOf(0, 1, 0, 1), listOf(got.approved, got.waiting, got.toFix, got.toSend))
        assertEquals("1 more to send", got.headline)
    }

    @Test
    fun unsentOptionalDocumentsAreNotCounted() {
        val got = summarise(documentRows(listOf(requirement("a", "validated"), requirement("extra", required = false)), null))
        assertEquals(1, got.total)
        assertEquals(SummaryTone.DONE, got.tone)
    }

    @Test
    fun describesWhatWasSent() {
        val nairobi = java.util.TimeZone.getTimeZone("Africa/Nairobi")
        class Case(val name: String, val document: VerificationDocument, val want: List<Pair<String, String>>)
        val cases = listOf(
            Case("sent late at night is the local day", VerificationDocument("pending_review", createdAt = "2026-11-13T22:30:00.123456Z"), listOf("Sent" to "14 Nov 2026")),
            Case("with an expiry date", VerificationDocument("pending_review", createdAt = "2026-11-13T09:00:00Z", expiresOn = "2027-03-31"), listOf("Sent" to "13 Nov 2026", "Expires" to "31 Mar 2027")),
            Case("a second copy", VerificationDocument("pending_review", createdAt = "2026-11-13T09:00:00+03:00", version = 2), listOf("Sent" to "13 Nov 2026", "Version" to "2")),
            Case("the first copy says nothing about versions", VerificationDocument("pending_review", version = 1), emptyList()),
            Case("an unreadable date is left out", VerificationDocument("pending_review", createdAt = "yesterday"), emptyList()),
        )
        for (case in cases) assertEquals(case.name, case.want, documentFacts(case.document, java.util.Locale.UK, nairobi))
    }

    @Test
    fun tellsAPdfFromAPhoto() {
        assertEquals(true, isPdf("%PDF-1.7 rest".toByteArray()))
        assertEquals(false, isPdf(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0)))
        assertEquals(false, isPdf("%PD".toByteArray()))
    }
}
