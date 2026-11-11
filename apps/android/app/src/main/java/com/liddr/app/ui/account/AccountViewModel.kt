package com.liddr.app.ui.account

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
    val error: String? = null,
    val notice: String? = null,
    val export: String? = null,
)

class AccountViewModel(private val api: LiddrApi, private val session: SessionManager) : ViewModel() {
    private val _ui = MutableStateFlow(AccountUiState())
    val ui: StateFlow<AccountUiState> = _ui.asStateFlow()

    init {
        load()
    }

    fun load() = attempt(loading = true) { _ui.update { it.copy(me = api.getMe()) } }

    fun saveName(name: String) = attempt { _ui.update { it.copy(me = api.updateMe(name)) } }

    fun deleteAccount() = attempt { api.deleteMe() }

    /** Fetches first, so a refusal shows before the person picks where to save. */
    fun prepareExport() = attempt { _ui.update { it.copy(export = api.exportMe(), notice = null) } }

    fun exportSaved(saved: Boolean) = _ui.update {
        it.copy(export = null, notice = if (saved) "Your data was saved." else null, error = if (saved) null else it.error)
    }

    fun exportFailed() = _ui.update { it.copy(export = null, error = "We couldn't save the file. Please try again.") }

    fun signOut() {
        viewModelScope.launch { session.signOut() }
    }

    private fun attempt(loading: Boolean = false, block: suspend () -> Unit) {
        _ui.update { it.copy(loading = loading, busy = !loading, error = null, notice = null) }
        viewModelScope.launch {
            try {
                block()
            } catch (e: ProblemException) {
                _ui.update { it.copy(error = e.message) }
            } catch (e: OfflineException) {
                _ui.update { it.copy(error = e.message) }
            } finally {
                _ui.update { it.copy(loading = false, busy = false) }
            }
        }
    }
}
