#include "KitModels.hpp"

#include <cstring>

namespace backline {

namespace {

struct ModelInfo {
    const char *id;
    const char *name;
    const char *description;
};

// Names and descriptions shown in the Kit Editor, in the same order as the
// recipes below.

constexpr ModelInfo kKickInfo[] = {
    {"kick.bigRoom", "Big Room", "Deep and boomy, with a long tail"},
    {"kick.tight", "Tight", "Short and punchy; stays out of the way"},
    {"kick.vintage", "Vintage", "Warm and round, like an old felt beater"},
    {"kick.punchy", "Punchy", "A hard click on top that cuts through loud guitars"},
};
constexpr KickModel kKicks[] = {
    {150.0f, 45.0f, 0.045f, 0.42f, 0.35f, 3000.0f, 0.30f, 0.0f},
    {185.0f, 58.0f, 0.022f, 0.16f, 0.60f, 4500.0f, 0.0f, 0.0f},
    {115.0f, 50.0f, 0.040f, 0.28f, 0.20f, 2000.0f, 0.0f, 0.0f},
    {200.0f, 52.0f, 0.030f, 0.24f, 0.85f, 5000.0f, 0.15f, 0.4f},
};

constexpr ModelInfo kSnareInfo[] = {
    {"snare.tightFunk", "Tight Funk", "High and crisp, with tight wires"},
    {"snare.fat70s", "Fat 70s", "Low, wide and loose"},
    {"snare.rimshot", "Rimshot Crack", "A sharp crack off the rim"},
    {"snare.piccolo", "Piccolo", "Very high and bright"},
    {"snare.brushes", "Brushes", "Soft swishes for quiet songs"},
    {"snare.crossStick", "Cross-stick", "A dry click off the rim, for ballads"},
};
constexpr SnareModel kSnares[] = {
    {225.0f, 400.0f, 0.045f, 0.90f, 0.09f, 5200.0f, 0.7f, 0.0f, SnareMode::Sticks},
    {170.0f, 300.0f, 0.085f, 0.70f, 0.17f, 2600.0f, 0.5f, 0.0f, SnareMode::Sticks},
    {205.0f, 360.0f, 0.050f, 0.80f, 0.12f, 4200.0f, 0.6f, 0.9f, SnareMode::Sticks},
    {310.0f, 560.0f, 0.035f, 1.00f, 0.08f, 6800.0f, 0.8f, 0.2f, SnareMode::Sticks},
    {190.0f, 340.0f, 0.040f, 0.80f, 0.22f, 2800.0f, 0.5f, 0.0f, SnareMode::Brushes},
    {380.0f, 900.0f, 0.014f, 0.00f, 0.01f, 2000.0f, 1.2f, 0.0f, SnareMode::CrossStick},
};

constexpr ModelInfo kHatInfo[] = {
    {"hat.bright14", "Bright 14\"", "Crisp and clean"},
    {"hat.dark15", "Dark 15\"", "Warm and a little washy"},
    {"hat.trashy", "Trashy", "Raw and dirty"},
};
constexpr HatModel kHats[] = {
    {1.7f, 9000.0f, 7000.0f, 1.1f, 0.030f, 0.34f, 0.25f},
    {1.3f, 6500.0f, 5000.0f, 0.9f, 0.045f, 0.50f, 0.35f},
    {2.1f, 8000.0f, 4500.0f, 0.6f, 0.035f, 0.45f, 0.65f},
};

constexpr ModelInfo kCymbalInfo[] = {
    {"cymbal.darkRide", "Dark Ride", "Warm and complex; sits under the band"},
    {"cymbal.bellRide", "Bell Ride", "A clear ping with a big bell"},
    {"cymbal.thinCrash", "Thin Crash", "Fast and bright; dies away quickly"},
    {"cymbal.bigCrash", "Big Crash", "Wide and loud, with a long wash"},
};
constexpr CymbalModel kCymbals[] = {
    {1.10f, 4500.0f, 0.90f, 0.15f, 0.15f},
    {1.40f, 6000.0f, 1.00f, 0.10f, 0.60f},
    {1.60f, 8000.0f, 0.45f, 0.60f, 0.0f},
    {1.25f, 6000.0f, 0.80f, 0.70f, 0.0f},
};

constexpr ModelInfo kTomInfo[] = {
    {"tom.rack12", "Rack 12\"", "High and tuneful"},
    {"tom.rack13", "Rack 13\"", "In the middle, full"},
    {"tom.floor16", "Floor 16\"", "Low and thunderous"},
};
constexpr TomModel kToms[] = {
    {185.0f, 1.45f, 0.050f, 0.24f, 0.35f},
    {150.0f, 1.45f, 0.055f, 0.30f, 0.30f},
    {95.0f, 1.55f, 0.065f, 0.45f, 0.25f},
};

template <typename T, size_t N>
constexpr uint8_t countOf(const T (&)[N]) {
    return static_cast<uint8_t>(N);
}

const ModelInfo *infoFor(int piece, uint8_t &count) {
    switch (familyOf(piece)) {
    case Family::Kick: count = countOf(kKickInfo); return kKickInfo;
    case Family::Snare: count = countOf(kSnareInfo); return kSnareInfo;
    case Family::Hat: count = countOf(kHatInfo); return kHatInfo;
    case Family::Cymbal: count = countOf(kCymbalInfo); return kCymbalInfo;
    case Family::Tom: count = countOf(kTomInfo); return kTomInfo;
    }
    count = 0;
    return nullptr;
}

// MARK: Built-in kits

struct BuiltIn {
    const char *name;
    // model index per piece, in BL_PIECE order: crash, ride, open hat, hi-hat, snare, high, low, floor tom, kick
    uint8_t models[BL_PIECE_COUNT];
    float kickTune, kickDecay, kickCharacter;
    float snareTune, snareDecay, snareTone, snareCharacter;
    float hatTone;
    float room, punch;
};

constexpr BuiltIn kBuiltIns[] = {
    {"Garage Kit", {3, 0, 1, 1, 1, 0, 1, 2, 2}, 0.0f, 0.5f, 0.5f, 0.0f, 0.5f, 0.5f, 0.5f, 0.5f, 0.30f, 0.30f},
    {"Studio Rock", {3, 1, 0, 0, 2, 0, 1, 2, 0}, 0.0f, 0.5f, 0.55f, 0.0f, 0.5f, 0.55f, 0.5f, 0.55f, 0.45f, 0.55f},
    {"Vintage 60s", {2, 0, 1, 1, 1, 0, 1, 2, 2}, -2.0f, 0.4f, 0.3f, -1.0f, 0.6f, 0.35f, 0.6f, 0.35f, 0.35f, 0.15f},
    {"Metal", {3, 1, 0, 0, 2, 0, 1, 2, 3}, 1.0f, 0.35f, 0.85f, 1.0f, 0.4f, 0.65f, 0.45f, 0.6f, 0.25f, 0.80f},
    {"Jazz Brushes", {2, 0, 1, 1, 4, 0, 1, 2, 2}, 3.0f, 0.35f, 0.3f, 0.0f, 0.5f, 0.5f, 0.5f, 0.45f, 0.40f, 0.10f},
    {"Lo-fi", {2, 0, 2, 2, 1, 0, 1, 2, 1}, 0.0f, 0.45f, 0.4f, -2.0f, 0.4f, 0.2f, 0.4f, 0.25f, 0.15f, 0.60f},
};

BLVoiceSettings neutral(uint8_t model) { return {model, 0.0f, 0.5f, 0.5f, 0.5f, 0.3f, 0.0f, 0.5f}; }

void fill(const BuiltIn &b, BLKit &kit) {
    for (int piece = 0; piece < BL_PIECE_COUNT; ++piece) kit.voices[piece] = neutral(b.models[piece]);
    BLVoiceSettings &kick = kit.voices[BL_PIECE_KICK];
    kick.tune = b.kickTune;
    kick.decay = b.kickDecay;
    kick.character = b.kickCharacter;
    kick.room = 0.15f; // kicks stay mostly dry
    BLVoiceSettings &snare = kit.voices[BL_PIECE_SNARE];
    snare.tune = b.snareTune;
    snare.decay = b.snareDecay;
    snare.tone = b.snareTone;
    snare.character = b.snareCharacter;
    snare.room = 0.45f;
    kit.voices[BL_PIECE_HI_HAT].tone = b.hatTone;
    kit.voices[BL_PIECE_OPEN_HAT] = kit.voices[BL_PIECE_HI_HAT];
    kit.voices[BL_PIECE_CRASH].room = 0.4f;
    kit.room = b.room;
    kit.punch = b.punch;
}

} // namespace

Family familyOf(int piece) {
    switch (piece) {
    case BL_PIECE_KICK: return Family::Kick;
    case BL_PIECE_SNARE: return Family::Snare;
    case BL_PIECE_HI_HAT:
    case BL_PIECE_OPEN_HAT: return Family::Hat;
    case BL_PIECE_RIDE:
    case BL_PIECE_CRASH: return Family::Cymbal;
    default: return Family::Tom;
    }
}

uint8_t modelCount(int piece) {
    uint8_t count = 0;
    infoFor(piece, count);
    return count;
}

const KickModel &kickModel(uint8_t i) { return kKicks[i < countOf(kKicks) ? i : 0]; }
const SnareModel &snareModel(uint8_t i) { return kSnares[i < countOf(kSnares) ? i : 0]; }
const HatModel &hatModel(uint8_t i) { return kHats[i < countOf(kHats) ? i : 0]; }
const CymbalModel &cymbalModel(uint8_t i) { return kCymbals[i < countOf(kCymbals) ? i : 0]; }
const TomModel &tomModel(uint8_t i) { return kToms[i < countOf(kToms) ? i : 0]; }

BLKit defaultKit() {
    BLKit kit;
    fill(kBuiltIns[0], kit);
    kit.room = 0.0f;
    kit.punch = 0.0f;
    return kit;
}

} // namespace backline

extern "C" {

uint8_t bl_kit_model_count(uint8_t piece) { return piece < BL_PIECE_COUNT ? backline::modelCount(piece) : 0; }

const char *bl_kit_model_id(uint8_t piece, uint8_t model) {
    uint8_t count = 0;
    const auto *info = piece < BL_PIECE_COUNT ? backline::infoFor(piece, count) : nullptr;
    return info && model < count ? info[model].id : nullptr;
}

const char *bl_kit_model_name(uint8_t piece, uint8_t model) {
    uint8_t count = 0;
    const auto *info = piece < BL_PIECE_COUNT ? backline::infoFor(piece, count) : nullptr;
    return info && model < count ? info[model].name : nullptr;
}

const char *bl_kit_model_description(uint8_t piece, uint8_t model) {
    uint8_t count = 0;
    const auto *info = piece < BL_PIECE_COUNT ? backline::infoFor(piece, count) : nullptr;
    return info && model < count ? info[model].description : nullptr;
}

int32_t bl_kit_model_index(uint8_t piece, const char *modelID) {
    uint8_t count = 0;
    const auto *info = piece < BL_PIECE_COUNT && modelID ? backline::infoFor(piece, count) : nullptr;
    for (uint8_t i = 0; info && i < count; ++i)
        if (std::strcmp(info[i].id, modelID) == 0) return i;
    return -1;
}

uint8_t bl_kit_builtin_count(void) { return backline::countOf(backline::kBuiltIns); }

const char *bl_kit_builtin_name(uint8_t index) {
    return index < bl_kit_builtin_count() ? backline::kBuiltIns[index].name : nullptr;
}

void bl_kit_builtin(uint8_t index, BLKit *out) {
    backline::fill(backline::kBuiltIns[index < bl_kit_builtin_count() ? index : 0], *out);
}

} // extern "C"
