@tool
class_name EchoThinkEventBus
extends Node


const _SIGNAL_NAMES = [
	&"session_connected",
	&"session_disconnected",
	&"task_updated",
	&"plan_ready",
	&"patch_ready",
	&"patch_applied",
	&"patch_rolled_back",
	&"asset_bundle_ready",
	&"asset_imported",
	&"approval_pending",
	&"approval_decided",
	&"log_analysis_ready",
	&"test_completed",
	&"context_snapshot_sent",
	&"connection_state_changed",
	&"error_occurred",
]


signal session_connected
signal session_disconnected
signal task_updated(task: TaskEnvelope)
signal plan_ready(plan: PlanRevision)
signal patch_ready(patch: PatchProposal)
signal patch_applied(changeset: ChangeSet)
signal patch_rolled_back(changeset_id: String)
signal asset_bundle_ready(bundle: AssetBundle)
signal asset_imported(bundle_id: String, success: bool)
signal approval_pending(ticket: ApprovalTicket)
signal approval_decided(ticket: ApprovalTicket)
signal log_analysis_ready(results: Dictionary)
signal test_completed(record: TestRunRecord)
signal context_snapshot_sent(snapshot_id: String)
signal connection_state_changed(state: String)
signal error_occurred(source: String, message: String)


func emit_error(source: String, message: String) -> void:
	error_occurred.emit(source.strip_edges(), message.strip_edges())


func reset() -> void:
	for signal_name_variant in _SIGNAL_NAMES:
		var signal_name: StringName = signal_name_variant
		if not has_signal(signal_name):
			continue

		var raw_connections: Variant = get_signal_connection_list(signal_name)
		if not (raw_connections is Array):
			continue

		for connection_variant in raw_connections:
			if not (connection_variant is Dictionary):
				continue

			var connection: Dictionary = connection_variant
			var target_callable: Callable = connection.get("callable", Callable())
			if not target_callable.is_valid():
				continue
			if is_connected(signal_name, target_callable):
				disconnect(signal_name, target_callable)
