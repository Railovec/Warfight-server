class_name Room

var players := {}      # peer_id -> player_id
var battle             # BattleManager
var id : int

func _init(room_id, p1, p2, battle_scene):

	id = room_id

	players[p1] = 1
	players[p2] = 2

	battle = battle_scene.instantiate()
	battle.start_game()

	print("🎮 Room ", id, " created")
