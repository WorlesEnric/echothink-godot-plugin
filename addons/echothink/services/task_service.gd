@tool
class_name EchoThinkTaskService
extends RefCounted


const TASKS_ENDPOINT := "/tasks"
const PLANS_ENDPOINT := "/plans"
const OUTLINE_PROPOSALS_ENDPOINT := "/outline/proposals"
const APPROVALS_ENDPOINT := "/approvals"


var _gateway_client: EchoThinkGatewayClient = null
var _event_bus: Object = null


func initialize(gateway: EchoThinkGatewayClient, events: Object) -> void:
	_gateway_client = gateway
	_event_bus = events


func get_task_list() -> Array[TaskEnvelope]:
	if _gateway_client == null:
		return []
	var response := await _gateway_client.api_request(TASKS_ENDPOINT, HTTPClient.METHOD_GET, {})
	return _task_array_from_variant(response.get("tasks", response.get("items", [])))


func get_task_details(work_item_id: String) -> TaskEnvelope:
	if work_item_id.strip_edges().is_empty() or _gateway_client == null:
		return TaskEnvelope.new()
	var response := await _gateway_client.api_request("%s/%s" % [TASKS_ENDPOINT, work_item_id], HTTPClient.METHOD_GET, {})
	if response.has("task") and response["task"] is Dictionary:
		return TaskEnvelope.from_dict(response["task"])
	return TaskEnvelope.from_dict(response)


func request_plan(context: ProjectContextSnapshot) -> String:
	if _gateway_client == null:
		return ""
	var response := await _gateway_client.api_request(PLANS_ENDPOINT, HTTPClient.METHOD_POST, {
		"context": context.to_dict(),
	})
	var plan_id := String(response.get("plan_id", response.get("request_id", ""))).strip_edges()
	if not plan_id.is_empty():
		_dispatch_event("plan.requested", {
			"plan_id": plan_id,
			"snapshot_id": context.snapshot_id,
		})
	return plan_id


func accept_plan(plan_id: String, selected_tasks: Array[int]) -> bool:
	if plan_id.strip_edges().is_empty() or _gateway_client == null:
		return false
	var response := await _gateway_client.api_request("%s/%s/accept" % [PLANS_ENDPOINT, plan_id], HTTPClient.METHOD_POST, {
		"selected_tasks": selected_tasks.duplicate(),
	})
	var accepted := bool(response.get("ok", false)) and not response.has("error")
	if accepted:
		_dispatch_event("plan.accepted", {
			"plan_id": plan_id,
			"selected_tasks": selected_tasks.duplicate(),
		})
	return accepted


func update_outline_proposal(proposal: Dictionary) -> String:
	if _gateway_client == null:
		return ""
	var response := await _gateway_client.api_request(OUTLINE_PROPOSALS_ENDPOINT, HTTPClient.METHOD_POST, proposal)
	var proposal_id := String(response.get("proposal_id", response.get("request_id", ""))).strip_edges()
	if not proposal_id.is_empty():
		_dispatch_event("outline.proposal_updated", {
			"proposal_id": proposal_id,
		})
	return proposal_id


func submit_approval(approval_id: String, decision: String, reason: String) -> bool:
	if approval_id.strip_edges().is_empty() or _gateway_client == null:
		return false
	var response := await _gateway_client.api_request("%s/%s/decision" % [APPROVALS_ENDPOINT, approval_id], HTTPClient.METHOD_POST, {
		"decision": decision.strip_edges(),
		"reason": reason.strip_edges(),
	})
	var accepted := bool(response.get("ok", false)) and not response.has("error")
	if accepted:
		_dispatch_event("approval.submitted", {
			"approval_id": approval_id,
			"decision": decision.strip_edges(),
		})
	return accepted


func get_pending_approvals() -> Array[ApprovalTicket]:
	if _gateway_client == null:
		return []
	var response := await _gateway_client.api_request("%s?decision=pending" % APPROVALS_ENDPOINT, HTTPClient.METHOD_GET, {})
	return _approval_array_from_variant(response.get("approvals", response.get("items", [])))


func _task_array_from_variant(value: Variant) -> Array[TaskEnvelope]:
	var tasks: Array[TaskEnvelope] = []
	if value is Array:
		for item in value:
			if item is Dictionary:
				tasks.append(TaskEnvelope.from_dict(item))
	return tasks


func _approval_array_from_variant(value: Variant) -> Array[ApprovalTicket]:
	var approvals: Array[ApprovalTicket] = []
	if value is Array:
		for item in value:
			if item is Dictionary:
				approvals.append(ApprovalTicket.from_dict(item))
	return approvals


func _dispatch_event(event_name: String, payload: Dictionary) -> void:
	if _event_bus == null or not is_instance_valid(_event_bus):
		return
	var event_payload := payload.duplicate(true)
	if _event_bus.has_method("publish"):
		_event_bus.call("publish", event_name, event_payload)
		return
	if _event_bus.has_method("dispatch"):
		_event_bus.call("dispatch", event_name, event_payload)
		return
	if _event_bus.has_method("emit_event"):
		_event_bus.call("emit_event", event_name, event_payload)
		return
	if _event_bus.has_signal("event_emitted"):
		_event_bus.emit_signal("event_emitted", event_name, event_payload)
