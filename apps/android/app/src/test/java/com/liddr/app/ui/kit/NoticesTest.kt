package com.liddr.app.ui.kit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NoticesTest {
    @Test
    fun aNewerNoticeReplacesTheOlder() {
        val notices = Notices()
        notices.show("We couldn't cancel the ride.")
        notices.show("You're offline.")
        assertEquals("You're offline.", notices.current.value?.message)
    }

    @Test
    fun anOldTimerDoesNotHideANewerNotice() {
        val notices = Notices()
        notices.show("Same words")
        val first = notices.current.value!!
        notices.show("Same words")
        notices.dismiss(first)
        assertEquals("Same words", notices.current.value?.message)
    }

    @Test
    fun dismissingTheShownNoticeHidesIt() {
        val notices = Notices()
        notices.show("Try again")
        notices.dismiss(notices.current.value!!)
        assertNull(notices.current.value)
    }

    @Test
    fun aFinishedTaskIsMarkedDoneAndAFailureIsNot() {
        val notices = Notices()
        notices.done("Your data was saved.")
        assertEquals(true, notices.current.value?.done)
        notices.show("We couldn't save the file.")
        assertEquals(false, notices.current.value?.done)
    }
}
