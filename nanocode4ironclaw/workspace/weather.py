#!/usr/bin/env python3
"""
Weather CLI Tool - Fetches and displays current weather for a given city.

Uses the wttr.in JSON API to retrieve weather data and displays a formatted
summary including temperature, conditions, humidity, and wind information.
"""

import argparse
import json
import sys
import urllib.parse
import urllib.request
import urllib.error


def fetch_weather_data(city):
    """Fetch weather data from wttr.in API for the specified city."""
    city_encoded = urllib.parse.quote(city)
    url = f"https://wttr.in/{city_encoded}?format=j1"

    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.loads(response.read().decode('utf-8'))
            return data
    except urllib.error.HTTPError as e:
        if e.code == 400 or e.code == 404:
            return None
        print(f"Error: API request failed with status {e.code}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"Error: Network request failed - {e.reason}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError:
        print("Error: Invalid response from API", file=sys.stderr)
        sys.exit(1)
    except TimeoutError:
        print("Error: Request timed out", file=sys.stderr)
        sys.exit(1)


def display_weather(data, city):
    """Display formatted weather information."""
    if data is None:
        print(f"Error: City '{city}' not found or invalid.", file=sys.stderr)
        sys.exit(1)

    try:
        current = data.get('current_condition', [{}])[0]
        area = data.get('nearest_area', [{}])[0]

        city_name = area.get('areaName', [{}])[0].get('value', city)
        country = area.get('country', [{}])[0].get('value', '')

        if country:
            city_display = f"{city_name}, {country}"
        else:
            city_display = city_name

        temperature_c = current.get('temp_C', 'N/A')
        temperature_f = current.get('temp_F', 'N/A')
        weather_desc = current.get('weatherDesc', [{}])[0].get('value', 'Unknown')
        humidity = current.get('humidity', 'N/A')
        wind_mph = current.get('windspeedMiles', 'N/A')
        wind_kph = current.get('windspeedKmph', 'N/A')
        wind_dir = current.get('winddir16Point', 'N/A')
        feels_like_c = current.get('FeelsLikeC', 'N/A')
        feels_like_f = current.get('FeelsLikeF', 'N/A')

        print(f"\nWeather for {city_display}")
        print("-" * 30)
        print(f"Temperature: {temperature_c}°C / {temperature_f}°F")
        print(f"Feels like:  {feels_like_c}°C / {feels_like_f}°F")
        print(f"Condition:   {weather_desc}")
        print(f"Humidity:    {humidity}%")
        print(f"Wind:        {wind_kph} km/h ({wind_mph} mph) from {wind_dir}")
        print()

    except (KeyError, IndexError, TypeError) as e:
        print(f"Error: Missing or invalid data in API response", file=sys.stderr)
        sys.exit(1)


def main():
    """Main entry point for the weather CLI tool."""
    parser = argparse.ArgumentParser(
        description="Get current weather information for a city."
    )
    parser.add_argument(
        "city",
        help="The city name to get weather for (e.g., London, Tokyo)"
    )

    args = parser.parse_args()

    data = fetch_weather_data(args.city)
    display_weather(data, args.city)


if __name__ == "__main__":
    main()
