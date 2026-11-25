package com.liddr.app.ui.account

import com.liddr.app.ui.kit.Notices

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.liddr.app.data.LiddrApi
import com.liddr.app.data.Me
import com.liddr.app.data.OfflineException
import com.liddr.app.data.ProblemException
import com.liddr.app.data.SessionManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class AccountUiState(
    val loading: Boolean = true,
    val busy: Boolean = false,
    val me: Me? = null,
    /** Why the account didn't load, or why the name was refused. Other failures go to the message bar. */
    val error: String? = null,
    val export: String? = null,
)

class AccountViewModel(private val api: LiddrApi, private val session: SessionManager, private val notices: Notices) : ViewModel() {
    private val _ui = MutableStateFlow(AccountUiState())
    val ui: StateFlow<AccountUiState> = _ui.asStateFlow()

    init {
        load()
    }

    fun load() = attempt(loading = true, inline = true) { _ui.update { it.copy(me = api.getMe()) } }

    fun saveName(name: String) = attempt(inline = true) { _ui.update { it.copy(me = api.updateMe(name)) } }

    fun deleteAccount() = attempt { api.deleteMe() }

    /** Fetches first, so a refusal shows before the person picks where to save. */
    fun prepareExport() = attempt { _ui.update { it.copy(export = api.exportMe()) } }

    fun exportSaved(saved: Boolean) {
        _ui.update { it.copy(export = null) }
        if (saved) notices.done("Your data was saved.")
    }

    fun exportFailed() {
        _ui.update { it.copy(export = null) }
        notices.show("We couldn't save the file.", "Try again", ::prepareExport)
    }

    fun signOut() {
        viewModelScope.launch { session.signOut() }
    }

    /** Runs an account action. A failure goes to the message bar, or onto the screen when [inline]. */
    private fun attempt(loading: Boolean = false, inline: Boolean = false, block: suspend () -> Unit) {
        _ui.update { it.copy(loading = loading, busy = !loading, error = null) }
        viewModelScope.launch {
            try {
                block()
            } catch (e: ProblemException) {
                failed(e.message, inline)
            } catch (e: OfflineException) {
                failed(e.message, inline)
            } finally {
                _ui.update { it.copy(loading = false, busy = false) }
            }
        }
    }

    private fun failed(message: String?, inline: Boolean) {
        val text = message ?: "Something went wrong. Please try again."
        if (inline) _ui.update { it.copy(error = text) } else notices.show(text)
    }
}
