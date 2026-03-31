extends Node

var units: Array = []
var barricades: Array = []

const TICK_RATE := 0.2
const MANA_RATE := 1
const DEFAULT_MELEE_RANGE := 1.5
var game_started := false
var next_spawn_id: int = 1
var bases := {}
var players := {}
var bases_hp := {}
var projectiles: Array = []  # aktívne projektily
var next_projectile_id: int = 1


func _ready() -> void:
	var t := Timer.new()
	t.wait_time = TICK_RATE
	t.autostart = true
	t.timeout.connect(tick)
	add_child(t)
	init_players()
	start_mana_loop()


func start_mana_loop():
	while true:
		await get_tree().create_timer(MANA_RATE).timeout
		if not game_started:
			continue
		regenerate_mana()


func regenerate_mana():
	for p in players.values():
		p.mana = min(p.mana + 1, p.max_mana)


func tick():
	if not game_started:
		return
	apply_buffs()
	apply_formation_bonuses()
	tick_slow_timers()
	tick_burn()
	tick_healers()
	tick_engineer_barricades()
	move_units()
	handle_combat()        
	tick_projectiles()     
	cleanup_dead_units()
	check_base_hit()
	tick_card_cooldowns()
	var snap = get_game_snapshot()
	var client := get_tree().get_root().find_child("Client", true, false)
	if client:
		client.update_snapshot(snap)
	


# ══════════════════════════════════════════
# BUFFY
# ══════════════════════════════════════════

func apply_buffs():
	for u in units:
		u.attack_speed = u.base_attack_speed
	for buffer in units:
		if not buffer.is_support:
			continue
		for u in units:
			if u.owner_id == buffer.owner_id and u != buffer:
				u.attack_speed = u.attack_speed * (1.0 - buffer.attack_speed_buff)


func apply_formation_bonuses():
	for u in units:
		if not u.formation_bonus:
			continue
		var allies_nearby := 0
		for other in units:
			if other == u or other.owner_id != u.owner_id or not other.formation_bonus:
				continue
			if abs(other.position - u.position) <= u.formation_range:
				allies_nearby += 1
		var should_be_active := allies_nearby >= 1
		if should_be_active and not u.formation_active:
			u.formation_active = true
			u.max_hp = int(float(u.max_hp) * (1.0 + u.formation_hp_bonus))
			u.hp = min(u.hp + int(float(u.max_hp) * u.formation_hp_bonus), u.max_hp)
		elif not should_be_active and u.formation_active:
			u.formation_active = false
			u.max_hp = int(float(u.max_hp) / (1.0 + u.formation_hp_bonus))
			u.hp = min(u.hp, u.max_hp)


func tick_slow_timers():
	for u in units:
		if u.slow_timer <= 0.0:
			continue
		u.slow_timer = max(0.0, u.slow_timer - TICK_RATE)
		if u.slow_timer <= 0.0 and u.base_speed > 0.0:
			u.speed = u.base_speed


func tick_burn():
	for u in units:
		if u.burn_timer <= 0.0:
			continue
		u.burn_timer = max(0.0, u.burn_timer - TICK_RATE)
		u.burn_tick_cooldown = max(0.0, u.burn_tick_cooldown - TICK_RATE)
		if u.burn_tick_cooldown <= 0.0:
			u.hp -= u.burn_damage
			u.burn_tick_cooldown = 1.0
			print("🔥 Burn DMG na unit ", u.spawn_id, " — HP: ", u.hp)


func tick_healers():
	for u in units:
		if not u.is_healer:
			continue
		u.heal_cooldown = max(0.0, u.heal_cooldown - TICK_RATE)
		if u.heal_cooldown > 0.0:
			continue
		var target := _get_lowest_hp_ally(u)
		if target != null:
			target.hp = min(target.hp + u.heal_amount, target.max_hp)
			u.heal_cooldown = u.attack_speed
			print("💚 Healer ", u.spawn_id, " lieči ", target.spawn_id, " +", u.heal_amount, " HP")


func _get_lowest_hp_ally(healer: Unit) -> Unit:
	var best: Unit = null
	var lowest := INF
	for u in units:
		if u.owner_id != healer.owner_id or u == healer:
			continue
		if u.hp < u.max_hp and float(u.hp) < lowest:
			lowest = float(u.hp)
			best = u
	return best


func tick_engineer_barricades():
	for u in units:
		if not u.has_meta("unit_type") or u.get_meta("unit_type") != "inzinier":
			continue
		u.attack_cooldown = max(0.0, u.attack_cooldown - TICK_RATE)
		if u.attack_cooldown <= 0.0:
			_spawn_barricade(u)
			u.attack_cooldown = 3.0


func _spawn_barricade(engineer: Unit):
	var offset := 10.0 if engineer.owner_id == 1 else -10.0
	barricades.append({
		"owner_id": engineer.owner_id,
		"hp": 80,
		"position": engineer.position + offset
	})
	print("🧱 Barikáda spawnutá na ", engineer.position + offset)


# ══════════════════════════════════════════
# POHYB
# ══════════════════════════════════════════

func move_units():
	for u in units:
		if u.is_ranged or u.is_healer:
			continue
		if u.ignore_units:
			_step_toward(u, float(bases[2]) if u.owner_id == 1 else float(bases[1]))
			continue
		var target := get_target(u)
		var destination: float
		if target != null:
			destination = target.position
		else:
			destination = float(bases[2]) if u.owner_id == 1 else float(bases[1])
		if abs(u.position - destination) <= u.attack_range and not u.move_while_attacking:
			continue
		_step_toward(u, destination)


func _step_toward(u: Unit, dest: float):
	if dest > u.position:
		u.position += u.speed
	else:
		u.position -= u.speed


# ══════════════════════════════════════════
# BOJ
# ══════════════════════════════════════════

func handle_combat():
	for attacker in units:
		attacker.attack_cooldown = max(0.0, attacker.attack_cooldown - TICK_RATE)
		if attacker.is_healer:
			continue
		if attacker.ignore_units and attacker.has_meta("unit_type") and attacker.get_meta("unit_type") == "trebuchet":
			if attacker.attack_cooldown <= 0.0:
				var base_id := 2 if attacker.owner_id == 1 else 1
				bases_hp[base_id] -= attacker.damage
				attacker.attack_cooldown = attacker.attack_speed
				print("🪨 Trebuchet DMG na základňu: ", attacker.damage, " HP: ", bases_hp[base_id])
			continue
		var target := get_target(attacker)
		if target == null:
			continue
		if abs(attacker.position - target.position) > attacker.attack_range:
			continue
		if attacker.attack_cooldown > 0.0:
			continue
		if attacker.is_ranged and attacker.projectile_in_flight:
			continue
		_do_attack(attacker, target)
		attacker.attack_cooldown = attacker.attack_speed


func _do_attack(attacker: Unit, primary_target: Unit):
	if attacker.is_ranged:
		attacker.projectile_in_flight = true
		projectiles.append({
			"id": next_projectile_id,
			"attacker_id": attacker.spawn_id,
			"owner": attacker.owner_id,
			"from_x": attacker.position,
			"to_x": primary_target.position,
			"pos": attacker.position,
			"unit_type": attacker.get_meta("unit_type", "musketier"),
			"damage": attacker.damage,
			"target_id": primary_target.spawn_id,
			"slow": attacker.slow_on_hit
		})
		next_projectile_id += 1
		return
	# Melee útok
	if attacker.splash_radius > 0.0:
		for u in units:
			if u.owner_id == attacker.owner_id:
				continue
			if abs(u.position - primary_target.position) <= attacker.splash_radius:
				var dealt = u.take_damage(attacker.damage)
				print("💥 Splash ", dealt, " DMG na unit ", u.spawn_id)
		for b in barricades:
			if b.owner_id == attacker.owner_id:
				continue
			if abs(b.position - primary_target.position) <= attacker.splash_radius:
				b.hp -= attacker.damage
	else:
		var dealt := primary_target.take_damage(attacker.damage)
		print("Unit ", attacker.spawn_id, " -> ", primary_target.spawn_id, " DMG: ", dealt, " HP: ", primary_target.hp)
	if attacker.slow_on_hit > 0.0:
		primary_target.apply_slow(attacker.slow_on_hit)
	if attacker.burn_on_hit:
		if primary_target.burn_timer <= 0.0:
			primary_target.burn_timer = 3.0
			primary_target.burn_tick_cooldown = 1.0
			print("🔥 Fakľar zapálil unit ", primary_target.spawn_id)
	if attacker.has_meta("unit_type") and attacker.get_meta("unit_type") == "panzer":
		for u in units:
			if u.owner_id != attacker.owner_id and abs(u.position - attacker.position) <= 5.0:
				u.take_damage(20)


# ══════════════════════════════════════════
# TARGETING
# ══════════════════════════════════════════

func get_target(attacker: Unit) -> Unit:
	if attacker.ignore_units:
		return null
	var candidates: Array = units.filter(func(u): return u.owner_id != attacker.owner_id)
	if attacker.has_meta("unit_type") and attacker.get_meta("unit_type") == "drak":
		var far := candidates.filter(func(u): return abs(u.position - attacker.position) > 100.0)
		if not far.is_empty():
			candidates = far
	if candidates.is_empty():
		return null
	match attacker.target_mode:
		Unit.TargetMode.NEAREST:
			var best: Unit = null
			var best_dist := INF
			for u in candidates:
				var d = abs(u.position - attacker.position)
				if d < best_dist:
					best_dist = d; best = u
			return best
		Unit.TargetMode.LOWEST_HP:
			var best: Unit = null
			var lowest := INF
			for u in candidates:
				if float(u.hp) < lowest:
					lowest = float(u.hp); best = u
			return best
		Unit.TargetMode.HIGHEST_HP:
			var best: Unit = null
			var highest := -1.0
			for u in candidates:
				if float(u.hp) > highest:
					highest = float(u.hp); best = u
			return best
	return null


# ══════════════════════════════════════════
# SMRŤ
# ══════════════════════════════════════════

func cleanup_dead_units():
	var dead := units.filter(func(u): return not u.is_alive())
	for u in dead:
		if u.death_explosion_radius > 0.0:
			print("💣 Výbuch unit ", u.spawn_id)
			for other in units:
				if other.owner_id != u.owner_id and abs(other.position - u.position) <= u.death_explosion_radius:
					other.take_damage(u.death_explosion_damage)
	units = units.filter(func(u): return u.is_alive())
	barricades = barricades.filter(func(b): return b.hp > 0)


# ══════════════════════════════════════════
# ZÁKLADNE
# ══════════════════════════════════════════

func check_base_hit():
	for u in units:
		if u.ignore_units:
			continue
		if u.owner_id == 1 and u.position >= bases[2] - u.speed - 1:
			u.attack_cooldown = u.attack_speed
			bases_hp[2] -= u.damage
		elif u.owner_id == 2 and u.position <= bases[1] + u.speed + 1:
			u.attack_cooldown = u.attack_speed
			bases_hp[1] -= u.damage
	if bases_hp[1] <= 0 and game_started:
		print_rich("[color=green]HRÁČ 2 VYHRAL[/color]")
		game_started = false
		await get_tree().create_timer(TICK_RATE).timeout
		get_parent().game_over(2)
	elif bases_hp[2] <= 0 and game_started:
		print_rich("[color=green]HRÁČ 1 VYHRAL[/color]")
		game_started = false
		await get_tree().create_timer(0.5).timeout
		get_parent().game_over(1)


# ══════════════════════════════════════════
# KARTY / SPAWN
# ══════════════════════════════════════════

var card_cooldowns: Dictionary = {1: {}, 2: {}}

func play_card(player_id: int, card_id: String):
	var player_units = units.filter(func(u): return u.owner_id == player_id)
	if player_units.size() >= 25:
		print("❌ Limit jednotiek dosiahnutý")
		return
	
	var cd = card_cooldowns[player_id].get(card_id, 0.0)
	if cd > 0.0:
		print("❌ Karta na cooldowne: ", cd)
		return
	
	var card = get_node("../CardDatabase").cards.get(card_id)
	if card == null:
		print("Neznáma karta: ", card_id); return
	var player = players.get(player_id)
	if player == null:
		return
	if player.mana < card.cost:
		print("Málo many"); return
	player.mana -= card.cost
	if card.type == "spell":
		_cast_spell(player_id, card)
	elif card.unit_type == "vojak_ww2":
		spawn_unit(player_id, card)
		spawn_unit(player_id, card)
	else:
		spawn_unit(player_id, card)
	print("Hráč ", player_id, " zahral ", card_id, " | mana: ", player.mana)
	
	card_cooldowns[player_id][card_id] = 3.0


func _cast_spell(player_id: int, card):
	if card.id == "letecky_utok":
		var enemy_base := float(bases[2]) if player_id == 1 else float(bases[1])
		var target_pos := enemy_base + randf_range(-200.0, 200.0)
		print("✈️ Letecký útok na ", target_pos)
		for u in units:
			if u.owner_id != player_id and abs(u.position - target_pos) <= 100.0:
				u.take_damage(45)
		if abs(enemy_base - target_pos) <= 100.0:
			var base_id := 2 if player_id == 1 else 1
			bases_hp[base_id] -= 45


func spawn_unit(owner_id: int, card) -> Unit:
	var u := Unit.new()
	u.owner_id = owner_id
	u.spawn_id = next_spawn_id
	next_spawn_id += 1
	u.position = float(bases[1]) if owner_id == 1 else float(bases[2])
	u.speed = card.speed
	u.base_speed = card.speed

	match card.unit_type:
		"jaskynny_muz":  # 3 many
			u.hp = 90; u.max_hp = 90; u.damage = 9; u.attack_speed = 1.0; u.attack_range = DEFAULT_MELEE_RANGE
			u.set_meta("unit_type", "jaskynny_muz")
		"lovec":  # 4 many
			u.hp = 80; u.max_hp = 80; u.damage = 14; u.attack_speed = 1.2
			u.is_ranged = true; u.attack_range = 80.0
			u.set_meta("unit_type", "lovec")
		"saman":  # 6 many
			u.hp = 100; u.max_hp = 100; u.damage = 2; u.attack_speed = 1.0
			u.is_healer = true; u.heal_amount = 8
			u.set_meta("unit_type", "saman")
		"mamut":  # 8 many
			u.hp = 300; u.max_hp = 300; u.damage = 22; u.attack_speed = 2.0; u.attack_range = DEFAULT_MELEE_RANGE
			u.death_explosion_radius = 50.0; u.death_explosion_damage = 35
			u.set_meta("unit_type", "mamut")
		"faklar":  # 7 many
			u.hp = 110; u.max_hp = 110; u.damage = 12; u.attack_speed = 1.0; u.attack_range = DEFAULT_MELEE_RANGE
			u.burn_on_hit = true
			u.set_meta("unit_type", "faklar")
		"jaskynny_strelec":  # 4 many
			u.hp = 70; u.max_hp = 70; u.damage = 16; u.attack_speed = 1.5
			u.is_ranged = true; u.attack_range = 100.0
			u.attack_cooldown = 0.0  # prvý výstrel okamžite
			u.set_meta("unit_type", "jaskynny_strelec")
		"bronzovy_vojak":  # 4 many
			u.hp = 120; u.max_hp = 120; u.damage = 13; u.attack_speed = 1.0; u.attack_range = DEFAULT_MELEE_RANGE
			u.set_meta("unit_type", "bronzovy_vojak")
		"vojnovy_voz":  # 7 many
			u.hp = 180; u.max_hp = 180; u.damage = 16; u.attack_speed = 0.8; u.attack_range = DEFAULT_MELEE_RANGE
			u.splash_radius = 15.0
			u.set_meta("unit_type", "vojnovy_voz")
		"lukostrelec":  # 5 many
			u.hp = 80; u.max_hp = 80; u.damage = 20; u.attack_speed = 1.5
			u.is_ranged = true; u.attack_range = 120.0; u.target_mode = Unit.TargetMode.LOWEST_HP
			u.set_meta("unit_type", "lukostrelec")
		"faraon":  # 9 many
			u.hp = 160; u.max_hp = 160; u.damage = 6; u.attack_speed = 1.5; u.attack_range = DEFAULT_MELEE_RANGE
			u.is_support = true; u.attack_speed_buff = 0.3
			u.set_meta("unit_type", "faraon")
		"legionar":  # 5 many
			u.hp = 150; u.max_hp = 150; u.damage = 15; u.attack_speed = 1.0; u.attack_range = DEFAULT_MELEE_RANGE
			u.formation_bonus = true
			u.set_meta("unit_type", "legionar")
		"balistar":  # 8 many
			u.hp = 100; u.max_hp = 100; u.damage = 38; u.attack_speed = 3.0
			u.attack_range = 60.0; u.splash_radius = 20.0
			u.set_meta("unit_type", "balistar")
		"gladiator":  # 6 many
			u.hp = 150; u.max_hp = 150; u.damage = 24; u.attack_speed = 1.0; u.attack_range = DEFAULT_MELEE_RANGE
			u.target_mode = Unit.TargetMode.HIGHEST_HP
			u.set_meta("unit_type", "gladiator")
		"saboter":  # 7 many
			u.hp = 130; u.max_hp = 130; u.damage = 12; u.attack_speed = 1.0; u.attack_range = DEFAULT_MELEE_RANGE
			u.ignore_units = true
			u.set_meta("unit_type", "saboter")
		"rytier":  # 6 many
			u.hp = 200; u.max_hp = 200; u.damage = 17; u.attack_speed = 1.2; u.attack_range = DEFAULT_MELEE_RANGE
			u.shield_percent = 0.5; u.shield_threshold = 0.5
			u.set_meta("unit_type", "rytier")
		"trebuchet":  # 9 many
			u.hp = 80; u.max_hp = 80; u.damage = 45; u.attack_speed = 4.0; u.attack_range = DEFAULT_MELEE_RANGE
			u.ignore_units = true; u.set_meta("unit_type", "trebuchet")
		"mnich":  # 5 many
			u.hp = 90; u.max_hp = 90; u.damage = 0; u.attack_speed = 1.0
			u.is_healer = true; u.heal_amount = 18; u.target_mode = Unit.TargetMode.LOWEST_HP
			u.set_meta("unit_type", "mnich")
		"drak":  # 10 many
			u.hp = 280; u.max_hp = 280; u.damage = 28; u.attack_speed = 1.2; u.attack_range = DEFAULT_MELEE_RANGE
			u.set_meta("unit_type", "drak")
		"musketier":  # 5 many
			u.hp = 80; u.max_hp = 80; u.damage = 25; u.attack_speed = 2.5
			u.is_ranged = true; u.attack_range = 700.0; u.attack_cooldown = 0.0
			u.set_meta("unit_type", "musketier")
		"parny_tank":  # 10 many
			u.hp = 380; u.max_hp = 380; u.damage = 32; u.attack_speed = 1.5; u.attack_range = DEFAULT_MELEE_RANGE
			u.move_while_attacking = true; u.set_meta("unit_type", "parny_tank")
		"inzinier":  # 7 many
			u.hp = 120; u.max_hp = 120; u.damage = 6; u.attack_speed = 1.0; u.attack_range = DEFAULT_MELEE_RANGE
			u.attack_cooldown = 0.0; u.set_meta("unit_type", "inzinier")
		"dynamiter":  # 6 many
			u.hp = 90; u.max_hp = 90; u.damage = 6; u.attack_speed = 1.0; u.attack_range = DEFAULT_MELEE_RANGE
			u.death_explosion_radius = 60.0; u.death_explosion_damage = 90
			u.set_meta("unit_type", "dynamiter")
		"vojak_ww2":  # 4 many
			u.hp = 110; u.max_hp = 110; u.damage = 18; u.attack_speed = 1.0; u.attack_range = DEFAULT_MELEE_RANGE
			u.set_meta("unit_type", "vojak_ww2")
		"panzer":  # 10 many
			u.hp = 380; u.max_hp = 380; u.damage = 35; u.attack_speed = 2.0; u.attack_range = DEFAULT_MELEE_RANGE
			u.move_while_attacking = true; u.set_meta("unit_type", "panzer")
		"odstrelec":  # 7 many
			u.hp = 70; u.max_hp = 70; u.damage = 55; u.attack_speed = 4.0
			u.is_ranged = true; u.attack_range = 200.0
			u.target_mode = Unit.TargetMode.HIGHEST_HP; u.slow_on_hit = 1.0
			u.set_meta("unit_type", "odstrelec")

	u.base_attack_speed = u.attack_speed
	units.append(u)
	
	
	var lvl = player_card_levels[owner_id].get(card.id, 1)
	var multiplier = 1.0 + (lvl - 1) * 0.1
	u.hp = int(u.hp * multiplier)
	u.max_hp = int(u.max_hp * multiplier)
	u.damage = int(u.damage * multiplier)
	
	print("Spawned: ", card.unit_type, " pre hráča ", owner_id)
	return u


# ══════════════════════════════════════════
# INIT / RESET / SNAPSHOT
# ══════════════════════════════════════════

func init_players():
	players[1] = {"mana": 0, "max_mana": 10}
	players[2] = {"mana": 0, "max_mana": 10}
	bases[1] = 150; bases[2] = 1002
	bases_hp[1] = 100; bases_hp[2] = 100


func start_game():
	print("🎮 BattleManager: hra začína")
	game_started = true


func reset_game():
	units.clear(); barricades.clear(); projectiles.clear()
	next_spawn_id = 1; game_started = false
	card_cooldowns = {1: {}, 2: {}}
	init_players()
	print("✅ BattleManager: reset hotový")


func client_play_card(player_id: int, card_id: String):
	play_card(player_id, card_id)


func get_game_snapshot() -> Dictionary:
	var snapshot := {"units": [], "players": {}, "barricades": []}
	for u in units:
		snapshot["units"].append({
			"id": u.spawn_id,
			"owner": u.owner_id,
			"hp": u.hp,
			"max_hp": u.max_hp,
			"pos": u.position,
			"speed": u.speed,
			"is_support": u.is_support,
			"is_ranged": u.is_ranged,
			"just_fired": u.attack_cooldown >= u.attack_speed * 0.8,
			"unit_type": u.get_meta("unit_type", "jaskynny_muz")  
		})
	for b in barricades:
		snapshot["barricades"].append({"owner": b.owner_id, "hp": b.hp, "pos": b.position})
	for id in players.keys():
		snapshot["players"][str(id)] = {"mana": players[id].mana, "max_mana": players[id].max_mana}
	for id in bases.keys():
		snapshot["players"]["base_hp_%d" % id] = bases_hp[id]
	snapshot["projectiles"] = projectiles.duplicate(true)
	snapshot["card_cooldowns"] = card_cooldowns.duplicate(true)
	return snapshot


func tick_projectiles():
	var speed := 50.0
	var arrived := []
	for p in projectiles:
		if p.to_x > p.pos:
			p.pos += speed
		else:
			p.pos -= speed
		if abs(p.pos - p.to_x) <= speed:
			arrived.append(p)
	for p in arrived:
		# print("✅ Projektil dorazil ID: ", p.id)
		var shooter := _find_unit_by_id(int(p.get("attacker_id", -1)))
		if shooter != null:
			shooter.projectile_in_flight = false
			#print("🔓 Reset projectile_in_flight pre shooter: ", shooter.spawn_id)
		var target := _find_unit_by_id(int(p.target_id))
		if target != null and target.is_alive():
			var dealt := target.take_damage(int(p.damage))
			#print("🎯 Projektil zasiahol unit ", target.spawn_id, " DMG: ", dealt)
			if p.get("slow", 0.0) > 0.0:
				target.apply_slow(p.slow)
	projectiles = projectiles.filter(func(p): return not arrived.has(p))
	
	
func _find_unit_by_id(spawn_id: int) -> Unit:
	for u in units:
		if u.spawn_id == spawn_id:
			return u
	return null


var player_card_levels: Dictionary = {1: {}, 2: {}}

func set_player_levels(player_id: int, levels: Dictionary):
	player_card_levels[player_id] = levels



func tick_card_cooldowns():
	for player_id in card_cooldowns.keys():
		for card_id in card_cooldowns[player_id].keys():
			card_cooldowns[player_id][card_id] = max(0.0, card_cooldowns[player_id][card_id] - TICK_RATE)
