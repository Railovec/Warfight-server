extends Node

const PORT := 9080
const TROPHY_RANGE := 150  # maximálny rozdiel trofejí pre match

var tcp_server := TCPServer.new()
var peers: Dictionary = {}       # peer_id -> WebSocketPeer
var players: Dictionary = {}     # peer_id -> player_id (1 alebo 2)
var player_info: Dictionary = {} # peer_id -> {username, trophies}
var next_peer_id := 1
var game_started := false
var ready_players := {}

# Matchmaking front — každý záznam: {peer_id, username, trophies}
var matchmaking_queue: Array = []

@onready var battle := $BattleManager


func _ready():
	var err := tcp_server.listen(PORT)
	if err != OK:
		push_error("❌ Server sa nepodarilo spustiť")
		set_process(false)
	else:
		print("✅ SERVER BEŽÍ NA PORTE ", PORT)

	var broadcast_timer := Timer.new()
	broadcast_timer.wait_time = 0.2
	broadcast_timer.autostart = true
	broadcast_timer.timeout.connect(broadcast_snapshot)
	add_child(broadcast_timer)


func _process(_delta):

	# nové pripojenia
	while tcp_server.is_connection_available():
		var conn = tcp_server.take_connection()
		var ws := WebSocketPeer.new()
		var err = ws.accept_stream(conn)

		if err != OK:
			print("⚠️ Ignored non-websocket connection")
			continue

		var peer_id := next_peer_id
		next_peer_id += 1
		peers[peer_id] = ws
		print("🟢 Client sa pripája:", peer_id)

	# spracovanie klientov
	for peer_id in peers.keys():
		var peer: WebSocketPeer = peers[peer_id]
		peer.poll()

		var state = peer.get_ready_state()

		if state == WebSocketPeer.STATE_OPEN:
			while peer.get_available_packet_count() > 0:
				var packet := peer.get_packet()
				if peer.was_string_packet():
					_handle_packet(peer_id, packet.get_string_from_utf8())

		elif state == WebSocketPeer.STATE_CLOSED:
			print("🔴 Client odpojený:", peer_id)
			_remove_from_queue(peer_id)
			peers.erase(peer_id)
			players.erase(peer_id)
			player_info.erase(peer_id)
			ready_players.erase(peer_id)


func _handle_packet(peer_id: int, text: String):
	var msg = JSON.parse_string(text)
	if msg == null:
		return

	var type = msg.get("type", "")

	if type == "ping":
		return

	if type == "find_match":
		_handle_find_match(peer_id, msg)

	if type == "play_card":
		var player_id = players.get(peer_id)
		if player_id == null:
			return
		battle.client_play_card(player_id, msg["card"])
		broadcast_snapshot()

	if type == "start_game":
		if not players.has(peer_id):
			return
		ready_players[peer_id] = true
		print("Player ready:", peer_id)
		check_start_game()


func _handle_find_match(peer_id: int, msg: Dictionary):
	# Ak už je v hre alebo vo fronte, ignoruj
	if players.has(peer_id):
		return
	if _is_in_queue(peer_id):
		return

	var username: String = msg.get("username", "Hráč")
	var trophies: int = int(msg.get("trophies", 100))

	player_info[peer_id] = {
		"username": username,
		"trophies": trophies
	}

	print("🔍 Hľadá match: ", username, " (", trophies, " trofejí)")

	# Skús nájsť súpera vo fronte
	var opponent_idx := _find_opponent(peer_id, trophies)

	if opponent_idx == -1:
		# Nikto vhodný nie je — zaradí do frontu
		matchmaking_queue.append({
			"peer_id": peer_id,
			"username": username,
			"trophies": trophies
		})
		_send(peer_id, {"type": "waiting"})
		print("⏳ ", username, " čaká vo fronte. Veľkosť frontu: ", matchmaking_queue.size())
	else:
		# Nájdený súper — spusti zápas
		var opponent = matchmaking_queue[opponent_idx]
		matchmaking_queue.remove_at(opponent_idx)
		_start_match(peer_id, opponent.peer_id)
	
	var deck: Array = msg.get("deck", [])
	player_info[peer_id] = {
		"username": username,
		"trophies": trophies,
		"deck": deck,
		"card_levels": msg.get("card_levels", {}),
	}
	print("🃏 Deck hráča ", username, ": ", deck)

func _find_opponent(peer_id: int, trophies: int) -> int:
	for i in matchmaking_queue.size():
		var candidate = matchmaking_queue[i]
		if candidate.peer_id == peer_id:
			continue
		if abs(candidate.trophies - trophies) <= TROPHY_RANGE:
			return i
	return -1


func _is_in_queue(peer_id: int) -> bool:
	for entry in matchmaking_queue:
		if entry.peer_id == peer_id:
			return true
	return false


func _remove_from_queue(peer_id: int):
	for i in matchmaking_queue.size():
		if matchmaking_queue[i].peer_id == peer_id:
			matchmaking_queue.remove_at(i)
			return


func _start_match(peer_id_1: int, peer_id_2: int):
	print("⚔️ Match nájdený! ", player_info[peer_id_1].username, " vs ", player_info[peer_id_2].username)

	players[peer_id_1] = 1
	players[peer_id_2] = 2

	_send(peer_id_1, {
		"type": "player_id",
		"id": 1,
		"opponent": player_info[peer_id_2].username,
		"opponent_trophies": player_info[peer_id_2].trophies,
		"deck": player_info[peer_id_1].get("deck", [])
	})

	_send(peer_id_2, {
		"type": "player_id",
		"id": 2,
		"opponent": player_info[peer_id_1].username,
		"opponent_trophies": player_info[peer_id_1].trophies,
		"deck": player_info[peer_id_1].get("deck", [])
	})

	battle.set_player_levels(1, player_info[peer_id_1].get("card_levels", {}))
	battle.set_player_levels(2, player_info[peer_id_2].get("card_levels", {}))
	start_game()


func _send(peer_id: int, data: Dictionary):
	if not peers.has(peer_id):
		return
	var peer: WebSocketPeer = peers[peer_id]
	if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		peer.send_text(JSON.stringify(data))


func send_snapshot(peer_id: int):
	if not peers.has(peer_id):
		return
	var peer: WebSocketPeer = peers[peer_id]
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	peer.send_text(JSON.stringify({
		"type": "snapshot",
		"data": battle.get_game_snapshot()
	}))


func broadcast_snapshot():
	if not game_started:
		return
	for id in peers.keys():
		send_snapshot(id)


func check_start_game():
	if game_started:
		return
	if ready_players.size() >= 2:
		start_game()


func start_game():
	game_started = true
	print("🎮 HRA ZAČÍNA")
	battle.start_game()

	for id in peers.keys():
		var peer: WebSocketPeer = peers[id]
		if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			peer.send_text(JSON.stringify({"type": "game_start"}))


func game_over(winner_player_id: int):
	print("🎯 game_over zavolaný! Víťaz: ", winner_player_id)
	game_started = false
	
	var winner_peer_id := -1
	var loser_peer_id := -1

	for peer_id in players.keys():
		if players[peer_id] == winner_player_id:
			winner_peer_id = peer_id
		else:
			loser_peer_id = peer_id

	# Pošli výsledok s info či vyhral alebo prehral
	for peer_id in peers.keys():
		var won = (peer_id == winner_peer_id)
		_send(peer_id, {
			"type": "game_over",
			"winner": winner_player_id,
			"won": won
		})
	print("🏆 Hráč ", winner_player_id, " vyhral!")

	await get_tree().create_timer(0.5).timeout
	_reset_server()


func _reset_server():
	print("🔄 Server sa resetuje, čaká na nových hráčov...")
	game_started = false
	ready_players.clear()
	matchmaking_queue.clear()
	
	await get_tree().create_timer(5.0).timeout
	
	for id in peers.keys():
		var peer: WebSocketPeer = peers[id]
		if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			peer.close()

	peers.clear()
	players.clear()
	player_info.clear()

	battle.reset_game()
	print("✅ Server čaká na pripojenie hráčov...")
