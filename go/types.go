package main

// Message represents a WebSocket message (request, response, or event).
type Message struct {
	Type   string                 `msgpack:"type"`
	ID     int                    `msgpack:"id"`
	Handle string                 `msgpack:"handle,omitempty"`
	Data   map[string]interface{} `msgpack:"data"`
}

// ErrorResponse creates an error message for a given request ID.
func ErrorResponse(id int, code, message string, fatal bool, handle string) Message {
	data := map[string]interface{}{
		"code":    code,
		"message": message,
		"fatal":   fatal,
	}
	if handle != "" {
		data["handle"] = handle
	}
	return Message{
		Type: "error",
		ID:   id,
		Data: data,
	}
}

// AckResponse creates an acknowledgement response.
func AckResponse(reqType string, id int, handle string, data map[string]interface{}) Message {
	if data == nil {
		data = map[string]interface{}{}
	}
	return Message{
		Type:   reqType + ":ack",
		ID:     id,
		Handle: handle,
		Data:   data,
	}
}

// Event creates an event message (id is always 0).
func Event(eventType, handle string, data map[string]interface{}) Message {
	if data == nil {
		data = map[string]interface{}{}
	}
	return Message{
		Type:   eventType,
		ID:     0,
		Handle: handle,
		Data:   data,
	}
}
