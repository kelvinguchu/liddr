package com.liddr.app.ui.booking

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.liddr.app.data.Delivery
import com.liddr.app.data.OfflineException
import com.liddr.app.data.ProblemException
import com.liddr.app.data.Realtime
import com.liddr.app.data.SendApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class IncomingUiState(
    val notificationId: String? = null,
    val delivery: Delivery? = null,
    val busy: Boolean = false,
    val error: String? = null,
)

/** Packages sent to this person that wait for them to confirm receipt. */
class IncomingViewModel(private val send: SendApi, realtime: Realtime) : ViewModel() {
    private val _ui = MutableStateFlow(IncomingUiState())
    val ui: StateFlow<IncomingUiState> = _ui.asStateFlow()

    init {
        // A package can arrive while the app is open, so the card appears without a restart.
        viewModelScope.launch {
            realtime.events.collect { if ((it.type == "send.updated" && it.status == "confirm_delivery") || it.type == "resync") check() }
        }
    }

    fun check() {
        viewModelScope.launch {
            val waiting = runCatching { send.listNotifications() }.getOrNull()
                ?.firstOrNull { it.eventType == "send.updated" && it.status == "confirm_delivery" && it.rideId != null } ?: return@launch
            val delivery = runCatching { send.getDelivery(waiting.rideId!!) }.getOrNull()
            if (delivery == null || delivery.confirmedAt != null) {
                runCatching { send.acknowledge(waiting.id) }
                return@launch
            }
            _ui.update { it.copy(notificationId = waiting.id, delivery = delivery) }
        }
    }

    fun confirm() {
        val delivery = _ui.value.delivery ?: return
        _ui.update { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                try {
                    send.confirmReceipt(delivery.rideId)
                } catch (e: ProblemException) {
                    if (e.code != "ALREADY_CONFIRMED") throw e
                }
                _ui.value.notificationId?.let { runCatching { send.acknowledge(it) } }
                _ui.update { IncomingUiState() }
                check()
            } catch (e: ProblemException) {
                _ui.update { it.copy(error = e.message) }
            } catch (e: OfflineException) {
                _ui.update { it.copy(error = e.message) }
            } finally {
                _ui.update { it.copy(busy = false) }
            }
        }
    }
}
