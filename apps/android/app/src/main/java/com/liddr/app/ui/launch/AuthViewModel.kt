package com.liddr.app.ui.launch

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.liddr.app.data.LiddrApi
import com.liddr.app.data.OfflineException
import com.liddr.app.data.ProblemException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class AuthUiState(
    val busy: Boolean = false,
    val error: String? = null,
    val challengeId: String? = null,
    val destination: String = "",
    val resendInSeconds: Int = 0,
)

/** Keeps sign-in moving across screen rotations. */
class AuthViewModel(private val api: LiddrApi) : ViewModel() {
    private val _ui = MutableStateFlow(AuthUiState())
    val ui: StateFlow<AuthUiState> = _ui.asStateFlow()

    private var method: AuthMethodUi? = null
    private var role: AccountRoleUi = AccountRoleUi.RIDER
    private var countdown: Job? = null

    fun sendCode(role: AccountRoleUi, method: AuthMethodUi, destination: String) {
        this.role = role
        this.method = method
        request(destination.trim())
    }

    fun resend() = request(_ui.value.destination)

    fun verify(code: String) {
        val challenge = _ui.value.challengeId ?: return
        val verifying = method ?: return
        if (_ui.value.busy) return
        run {
            if (verifying.method == "phone_otp") api.verifyOtp(challenge, code) else api.verifyEmailOtp(challenge, code)
        }
    }

    /** Returns from code entry to change the phone number or email. */
    fun editDestination() {
        countdown?.cancel()
        _ui.update { it.copy(challengeId = null, error = null, resendInSeconds = 0) }
    }

    fun clearError() = _ui.update { it.copy(error = null) }

    private fun request(destination: String) {
        val sending = method ?: return
        if (_ui.value.busy) return
        run {
            val challenge = if (sending.method == "phone_otp") {
                api.requestOtp(destination, role.apiValue)
            } else {
                api.requestEmailOtp(destination)
            }
            _ui.update { it.copy(challengeId = challenge.challengeId, destination = destination) }
            startCountdown(RESEND_SECONDS)
        }
    }

    private fun run(block: suspend () -> Unit) {
        _ui.update { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                block()
            } catch (e: ProblemException) {
                e.retryAfterSeconds?.let(::startCountdown)
                _ui.update { it.copy(error = e.message) }
            } catch (e: OfflineException) {
                _ui.update { it.copy(error = e.message) }
            } finally {
                _ui.update { it.copy(busy = false) }
            }
        }
    }

    private fun startCountdown(seconds: Int) {
        countdown?.cancel()
        countdown = viewModelScope.launch {
            for (left in seconds downTo 1) {
                _ui.update { it.copy(resendInSeconds = left) }
                delay(1_000)
            }
            _ui.update { it.copy(resendInSeconds = 0) }
        }
    }

    private companion object {
        /** The API allows one code per phone every 30 seconds. */
        const val RESEND_SECONDS = 30
    }
}
