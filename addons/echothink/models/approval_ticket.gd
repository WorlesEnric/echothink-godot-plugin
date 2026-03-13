@tool
class_name ApprovalTicket
extends RefCounted


const DECISION_PENDING := "pending"
const DECISION_APPROVED := "approved"
const DECISION_REJECTED := "rejected"


var approval_id: String = ""
var work_item_id: String = ""
var task_run_id: String = ""
var requested_by: String = ""
var risk_level: String = ""
var approval_policy: String = ""
var decision: String = DECISION_PENDING
var decided_by: String = ""
var decided_at: String = ""
var reason: String = ""
var created_at: String = ""


func to_dict() -> Dictionary:
	return {
		"approval_id": approval_id,
		"work_item_id": work_item_id,
		"task_run_id": task_run_id,
		"requested_by": requested_by,
		"risk_level": risk_level,
		"approval_policy": approval_policy,
		"decision": decision,
		"decided_by": decided_by,
		"decided_at": decided_at,
		"reason": reason,
		"created_at": created_at,
	}


static func from_dict(data: Dictionary) -> ApprovalTicket:
	var ticket := ApprovalTicket.new()
	ticket.approval_id = _string_value(data.get("approval_id", ""))
	ticket.work_item_id = _string_value(data.get("work_item_id", ""))
	ticket.task_run_id = _string_value(data.get("task_run_id", ""))
	ticket.requested_by = _string_value(data.get("requested_by", ""))
	ticket.risk_level = _string_value(data.get("risk_level", ""))
	ticket.approval_policy = _string_value(data.get("approval_policy", ""))
	ticket.decision = _string_value(data.get("decision", DECISION_PENDING), DECISION_PENDING)
	ticket.decided_by = _string_value(data.get("decided_by", ""))
	ticket.decided_at = _string_value(data.get("decided_at", ""))
	ticket.reason = _string_value(data.get("reason", ""))
	ticket.created_at = _string_value(data.get("created_at", ""))
	return ticket


func is_pending() -> bool:
	return decision.to_lower() == DECISION_PENDING


func is_approved() -> bool:
	return decision.to_lower() == DECISION_APPROVED


static func _string_value(value: Variant, default_value: String = "") -> String:
	return default_value if value == null else str(value)
