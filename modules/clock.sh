#!/bin/bash
# vim:set tabstop=2 softtabstop=2 shiftwidth=2 expandtab:
#
# Copyright (C) 2026 Pavel Vitis <pavelvitis@gmail.com>
#
# Distributed under terms of the MIT license.

# This live module renders the localized date and time for the ticker. It
# colors the time from white in daylight through amber at dawn and dusk to a
# configurable blue at night, and shows minutes until complete darkness during
# dusk.
# Coordinates necessary for the dusk/dawn solar elevation calculations come
# from the first configured GNOME Weather location; Prague is a fallback when
# it cannot be read. Solar calculations run at most once per minute, while
# clock_status renders the current time on each ticker update.
# Set CLOCK_NIGHT_COLOR to a #RRGGBB value to customize the full-night color.


CLOCK_LATITUDE=""
CLOCK_LONGITUDE=""
CLOCK_SOLAR_MINUTE=-1
CLOCK_COLOR="#ffffff"
CLOCK_SOLAR_ICON="☀"
CLOCK_DARKNESS_MINUTES=""

# User-adjustable full-night color. Must use the #RRGGBB form.
readonly CLOCK_NIGHT_COLOR="${CLOCK_NIGHT_COLOR:-#70809d}"


# Read the first GNOME Weather location and cache its coordinates in degrees.
#
# GNOME stores latitude and longitude in radians. If no configured location can
# be parsed, Prague is used as a stable fallback so clock rendering continues.
# Arguments: none.
# Output: none.
# Side effects: sets CLOCK_LATITUDE and CLOCK_LONGITUDE.
# Returns: zero.
initialize_clock_location() {
  local locations latitude_radians longitude_radians

  locations="$(gsettings get org.gnome.Weather locations 2>/dev/null)" || true
  if [[ "$locations" =~ \[\(([+-]?[0-9]+([.][0-9]+)?),[[:space:]]*([+-]?[0-9]+([.][0-9]+)?)\)\] ]]; then
    latitude_radians="${BASH_REMATCH[1]}"
    longitude_radians="${BASH_REMATCH[3]}"
    read -r CLOCK_LATITUDE CLOCK_LONGITUDE < <(
      awk -v lat="$latitude_radians" -v lon="$longitude_radians" \
        'BEGIN { pi = atan2(0, -1); print lat * 180 / pi, lon * 180 / pi }'
    )
  else
    # Prague
    CLOCK_LATITUDE="50.0755"
    CLOCK_LONGITUDE="14.4378"
  fi
}


# Calculate solar elevation for an epoch and geographic coordinates.
#
# Uses a compact astronomical approximation based on the Sun's ecliptic
# longitude and local sidereal time. Accuracy is sufficient for coloring the
# several-minute dawn/dusk transition, not for navigation.
# Arguments:
#   $1 - Unix timestamp in seconds.
#   $2 - Latitude in degrees, north positive.
#   $3 - Longitude in degrees, east positive.
# Output: solar elevation in degrees with four decimal places.
# Returns: the status of awk.
clock_solar_elevation() {
  awk -v epoch="$1" -v latitude="$2" -v longitude="$3" '
    function radians(degrees) { return degrees * pi / 180 }
    function normalize(degrees) {
      degrees %= 360
      return degrees < 0 ? degrees + 360 : degrees
    }
    BEGIN {
      pi = atan2(0, -1)
      days = epoch / 86400 + 2440587.5 - 2451545.0
      mean_longitude = normalize(280.460 + 0.9856474 * days)
      mean_anomaly = normalize(357.528 + 0.9856003 * days)
      ecliptic_longitude = mean_longitude + \
        1.915 * sin(radians(mean_anomaly)) + \
        0.020 * sin(radians(2 * mean_anomaly))
      obliquity = 23.439 - 0.0000004 * days
      right_ascension = atan2(cos(radians(obliquity)) * \
        sin(radians(ecliptic_longitude)), cos(radians(ecliptic_longitude))) \
        * 180 / pi
      right_ascension = normalize(right_ascension)
      declination = atan2(sin(radians(obliquity)) * \
        sin(radians(ecliptic_longitude)), \
        sqrt(1 - (sin(radians(obliquity)) * \
        sin(radians(ecliptic_longitude))) ^ 2))
      sidereal = normalize((18.697374558 + 24.06570982441908 * days) * 15 \
        + longitude)
      hour_angle = normalize(sidereal - right_ascension)
      if (hour_angle > 180) hour_angle -= 360
      sine_elevation = sin(radians(latitude)) * sin(declination) + \
        cos(radians(latitude)) * cos(declination) * cos(radians(hour_angle))
      elevation = atan2(sine_elevation, sqrt(1 - sine_elevation ^ 2)) \
        * 180 / pi
      printf "%.4f\n", elevation
    }
  '
}


# Calculate whole minutes remaining until the descending Sun reaches -6
# degrees, the threshold used by the clock for complete darkness.
# Arguments:
#   $1 - current solar elevation in degrees.
#   $2 - current Unix timestamp in seconds (defaults to EPOCHSECONDS).
# Output: positive integer minutes during dusk; nothing otherwise.
# Returns: zero when a dusk crossing is found; nonzero otherwise.
clock_minutes_until_darkness() {
  local elevation="$1"
  local epoch="${2:-$EPOCHSECONDS}"
  local future_elevation low=0 high=10800 middle remaining

  awk -v elevation="$elevation" \
    'BEGIN { exit !(elevation > -6 && elevation < 6) }' || return 1

  future_elevation="$(clock_solar_elevation "$((epoch + 60))" \
    "$CLOCK_LATITUDE" "$CLOCK_LONGITUDE")" || return 1
  awk -v current="$elevation" -v future="$future_elevation" \
    'BEGIN { exit !(future < current) }' || return 1

  future_elevation="$(clock_solar_elevation "$((epoch + high))" \
    "$CLOCK_LATITUDE" "$CLOCK_LONGITUDE")" || return 1
  awk -v elevation="$future_elevation" \
    'BEGIN { exit !(elevation <= -6) }' || return 1

  while ((high - low > 60)); do
    middle=$(((low + high) / 2))
    future_elevation="$(clock_solar_elevation "$((epoch + middle))" \
      "$CLOCK_LATITUDE" "$CLOCK_LONGITUDE")" || return 1
    if awk -v elevation="$future_elevation" \
      'BEGIN { exit !(elevation <= -6) }'; then
      high="$middle"
    else
      low="$middle"
    fi
  done

  remaining=$(((high + 59) / 60))
  ((remaining > 0)) || return 1
  printf '%d' "$remaining"
}


# Update CLOCK_COLOR from the current solar elevation at the GNOME location.
#
# The clock is dark blue at/below -6 degrees (night), warm amber at the horizon
# (dawn/dusk), and white at/above +6 degrees (daylight). Colors are linearly
# interpolated between those points. Calculation is limited to once per minute.
# Arguments: none.
# Output: none.
# Side effects: updates CLOCK_SOLAR_MINUTE, CLOCK_COLOR, CLOCK_SOLAR_ICON, and
# CLOCK_DARKNESS_MINUTES.
# Returns: zero, retaining white if an elevation cannot be calculated.
update_clock_color() {
  local current_minute elevation night_red night_green night_blue

  current_minute=$((EPOCHSECONDS / 60))
  ((current_minute != CLOCK_SOLAR_MINUTE)) || return 0
  CLOCK_SOLAR_MINUTE="$current_minute"

  [[ -n "$CLOCK_LATITUDE" ]] || initialize_clock_location
  elevation="$(clock_solar_elevation "$EPOCHSECONDS" \
    "$CLOCK_LATITUDE" "$CLOCK_LONGITUDE")" || return 0

  CLOCK_DARKNESS_MINUTES="$(
    clock_minutes_until_darkness "$elevation" "$EPOCHSECONDS"
  )" ||
    CLOCK_DARKNESS_MINUTES=""

  if awk -v elevation="$elevation" 'BEGIN { exit !(elevation >= 0) }'; then
    CLOCK_SOLAR_ICON="☀"
  else
    CLOCK_SOLAR_ICON="☾"
  fi

  if [[ "$CLOCK_NIGHT_COLOR" =~ ^#[0-9a-fA-F]{6}$ ]]; then
    night_red=$((16#${CLOCK_NIGHT_COLOR:1:2}))
    night_green=$((16#${CLOCK_NIGHT_COLOR:3:2}))
    night_blue=$((16#${CLOCK_NIGHT_COLOR:5:2}))
  else
    night_red=112
    night_green=128
    night_blue=157
  fi

  CLOCK_COLOR="$(awk -v elevation="$elevation" \
    -v night_red="$night_red" -v night_green="$night_green" \
    -v night_blue="$night_blue" '
    function channel(start, finish, fraction) {
      return int(start + (finish - start) * fraction + 0.5)
    }
    BEGIN {
      if (elevation <= -6) {
        red = night_red; green = night_green; blue = night_blue
      } else if (elevation < 0) {
        fraction = (elevation + 6) / 6
        red = channel(night_red, 255, fraction)
        green = channel(night_green, 179, fraction)
        blue = channel(night_blue, 107, fraction)
      } else if (elevation < 6) {
        fraction = elevation / 6
        red = 255
        green = channel(179, 255, fraction)
        blue = channel(107, 255, fraction)
      } else {
        red = 255; green = 255; blue = 255
      }
      printf "#%02x%02x%02x", red, green, blue
    }
  ')"
}


# Render the localized date and solar-colored time for the ticker.
#
# The date retains the original blue color. Only the time uses the computed
# daylight/twilight/night color. During dusk, minutes until complete darkness
# precede the solar icon. Format: "Fri 14 Aug 2026 W33 20:31:03 24m ☾" in two
# Pango foreground spans.
# Arguments: none.
# Output: Pango markup on standard output.
# Returns: the status of printf.
clock_status() {
  local darkness=""

  update_clock_color
  [[ -z "$CLOCK_DARKNESS_MINUTES" ]] ||
    darkness=" ${CLOCK_DARKNESS_MINUTES}m"$'\u2009' # Thin space
  printf '<span foreground="#00CED1">%s</span>' \
    "$(LC_TIME= date +'%a %_d %b %Y W%V')"
  printf '<span foreground="%s">  %s  %s%s </span>' "$CLOCK_COLOR" \
    "$(date +'%T')" "$darkness" "$CLOCK_SOLAR_ICON"
}
