extends Node
class_name Unit

var hp: int
var max_hp: int
var damage: int
var owner_id: int
var spawn_id: int
var position: float = 0.0
var speed: float
var attack_speed: float = 1.0
var attack_cooldown: float = 0.0
var base_attack_speed: float = 1.0
var projectile_spawned: bool = false  # či už bol vystrelený projektil
var projectile_in_flight: bool = false
var level: int = 1


# Support / buff
var is_support: bool = false
var attack_speed_buff: float = 0.0

# Heal
var is_healer: bool = false
var heal_amount: int = 0
var heal_cooldown: float = 0.0

# Ranged
var is_ranged: bool = false
var attack_range: float = 1.5  # default melee, ranged nastavia väčší

# Splash
var splash_radius: float = 0.0  # 0 = žiadny splash

# On death explosion
var death_explosion_radius: float = 0.0
var death_explosion_damage: int = 0

# Ignore units (sabotér, trebuchet) — ide priamo na základňu
var ignore_units: bool = false

# Shield (rytier) — blokuje % DMG kým hp > shield_threshold
var shield_percent: float = 0.0       # napr. 0.5 = blokuje 50% DMG
var shield_threshold: float = 0.5     # kým hp > 50% max_hp

# Move while attacking (parný tank)
var move_while_attacking: bool = false

# Formation bonus (legionár)
var formation_bonus: bool = false
var formation_range: float = 30.0
var formation_hp_bonus: float = 0.3   # +30% HP
var formation_active: bool = false

# Double spawn — handled in battle_manager, not here

# Targeting mode
enum TargetMode { NEAREST, LOWEST_HP, HIGHEST_HP }
var target_mode: TargetMode = TargetMode.NEAREST

# Spell — jednorazový efekt, nie jednotka
var is_spell: bool = false

# Slow on hit
var slow_on_hit: float = 0.0     # sekundy spomalenia
var slow_timer: float = 0.0      # zostatok spomalenia
var base_speed: float = 0.0      # uložená pôvodná rýchlosť

# Burn (Fakľar)
var burn_on_hit: bool = false    # či útočník zapáli cieľ
var burn_timer: float = 0.0     # zostatok horenia (3s)
var burn_damage: int = 5        # damage za tik
var burn_tick_cooldown: float = 0.0  # cooldown medzi burn tikmi (1s)

# Internal — skip targeting for saboteur/trebuchet path
var reached_base: bool = false

func is_alive() -> bool:
	return hp > 0

func take_damage(amount: int) -> int:
	var actual := amount
	# Shield — blokuje % DMG kým hp > threshold
	if shield_percent > 0.0 and max_hp > 0:
		if float(hp) / float(max_hp) > shield_threshold:
			actual = int(float(amount) * (1.0 - shield_percent))
	hp -= actual
	return actual

func apply_slow(duration: float):
	if slow_timer <= 0.0 and base_speed > 0.0:
		slow_timer = duration
		speed = base_speed * 0.3
	elif duration > slow_timer:
		slow_timer = duration
