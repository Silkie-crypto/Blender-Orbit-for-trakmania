#name "Blender Orbit"
#author "Silkie"
#category "Map Editor"

// Blender Orbit v1.0.0
//
// 1.0.0 = 0.3.0 with Duplicate, Scale, Delete and Cancel left out (planned for later).
// Also: WASD lateral camera movement (hold Shift to move faster).
// Changes since 0.2.0:
//  - Camera input is now event driven (OnMouseMove / OnMouseButton / OnMouseWheel)
//    instead of polling inside Render().
//  - Orbit and pan are smoothed (exponential damping) and step-limited to reduce
//    the jerky motion that tends to cause motion sickness.
//  - Pan is now truly screen-relative and scales with zoom distance.
//  - Plugin camera control is released automatically after input goes idle
//    (before, zooming left custom processing switched on forever).
//  - Key bindings are real: strings are parsed, matched against key presses,
//    and can be captured by pressing the key you want.
//  - Handled keys are blocked so the game does not ALSO react to them.
//  - Smooth focus uses real frame time instead of assuming 60 FPS.
//  - Removed per-mouse-move print() spam and ~20 obsolete test buttons.

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

[Setting category="Diagnostics"]
bool EnableDiagnostic = true;

[Setting category="Camera"]
float OrbitSensitivity = 0.005f;

[Setting category="Camera"]
float PanSensitivity = 0.1f;

[Setting category="Camera"]
bool ScalePanWithDistance = true;

[Setting category="Camera"]
float ZoomSensitivity = 1.0f;

[Setting category="Camera"]
bool InvertZoom = false;

[Setting category="Camera"]
float CloseZoomSpeed = 3.0f;

// 0 = no smoothing (raw), higher = snappier, lower = floatier.
[Setting category="Camera"]
float CameraSmoothing = 14.0f;

// Max rotation applied in one frame, in radians. Prevents sudden whips.
[Setting category="Camera"]
float MaxOrbitStep = 0.08f;

[Setting category="Camera"]
bool SmoothCameraFocus = true;

[Setting category="Camera"]
float FocusTransitionSpeed = 8.0f;

[Setting category="Camera"]
bool InvertOrbitY = false;

[Setting category="Camera"]
bool InvertPanX = false;

[Setting category="Camera"]
bool InvertPanY = false;

[Setting category="Camera"]
bool EnableWASD = true;

// World units per second at the reference distance (see ScalePanWithDistance).
[Setting category="Camera"]
float WasdSpeed = 100.0f;

[Setting category="Camera"]
bool InvertWASDStrafe = false;

[Setting category="Window"]
bool g_ShowWindow = true;

[Setting category="Bindings"]
string Bind_Orbit = "MouseRight";

[Setting category="Bindings"]
string Bind_Pan = "MouseMiddle";

[Setting category="Bindings"]
string Bind_Zoom = "MouseWheel";

[Setting category="Bindings"]
string Bind_Select = "MouseLeft";

[Setting category="Bindings"]
string Bind_Focus = "F";

[Setting category="Bindings"]
string Bind_Move = "G";

[Setting category="Bindings"]
string Bind_Rotate = "R";

[Setting category="Bindings"]
string Bind_RotateReverse = "Shift+R";

[Setting category="Bindings"]
string Bind_Raise = "PageUp";

[Setting category="Bindings"]
string Bind_Lower = "PageDown";

[Setting category="Bindings"]
string Bind_MoveForward = "W";

[Setting category="Bindings"]
string Bind_MoveBack = "Z";

[Setting category="Bindings"]
string Bind_MoveLeft = "A";

[Setting category="Bindings"]
string Bind_MoveRight = "D";

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

enum PluginPage
{
    Camera,
    Bindings,
    Diagnostics
}

PluginPage g_Page = PluginPage::Camera;
string g_StatusMessage = "Ready.";

// Modifier tracking
bool g_Shift = false;
bool g_Ctrl = false;
bool g_Alt = false;

// Held movement keys and smoothed keyboard camera movement
bool g_KeyForward = false;
bool g_KeyBack = false;
bool g_KeyLeft = false;
bool g_KeyRight = false;
bool g_KbActive = false;
vec3 g_KbTarget = vec3(0, 0, 0);
vec3 g_MoveVel = vec3(0, 0, 0);

// Camera drag state
bool g_Orbiting = false;
bool g_Panning = false;
vec2 g_LastMouse = vec2(-1, -1);

float g_H = 0.0f;           // tracked orbit angles (we write absolute values)
float g_V = 0.0f;
float g_PendingH = 0.0f;    // input not yet applied (for smoothing)
float g_PendingV = 0.0f;
vec3 g_PanTarget = vec3(0, 0, 0);
float g_PendingPanR = 0.0f;
float g_PendingPanU = 0.0f;

// Custom processing ownership
bool g_CustomActive = false;
float g_IdleMs = 0.0f;

// Zoom / focus
float g_CloseZoomOffset = 0.0f;
bool g_FocusAnimating = false;
vec3 g_FocusTarget = vec3(0, 0, 0);

// Pending (unconfirmed) mouse bindings
string PendingOrbit = "";
string PendingPan = "";
bool IsCapturingBinding = false;
string CapturingAction = "";

// Key rebinding capture
string g_CaptureKeyAction = "";

array<string> g_KeyActions = {
    "Focus", "Move", "Rotate", "RotateReverse",
    "Raise", "Lower",
    "MoveForward", "MoveBack", "MoveLeft", "MoveRight"
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

void Main()
{
    InitializePendingBindings();
}

void SetStatus(const string &in message)
{
    g_StatusMessage = message;
}

CGameCtnEditorFree@ GetEditor()
{
    auto app = cast<CTrackMania>(GetApp());
    if (app is null)
        return null;
    return cast<CGameCtnEditorFree>(app.Editor);
}

CGameEditorPluginMap@ GetPlugin()
{
    auto editor = GetEditor();
    if (editor is null)
        return null;
    return editor.PluginMapType;
}

float SmoothFraction(float rate, float seconds)
{
    if (rate <= 0.0f)
        return 1.0f;
    return 1.0f - Math::Exp(-rate * seconds);
}

void TakeCameraControl(CGameEditorPluginMap@ plugin)
{
    plugin.EnableEditorInputsCustomProcessing = true;
    g_CustomActive = true;
    g_IdleMs = 0.0f;
}

void ReleaseCameraControl()
{
    auto plugin = GetPlugin();
    if (plugin !is null)
        plugin.EnableEditorInputsCustomProcessing = false;
    g_CustomActive = false;
    g_IdleMs = 0.0f;
}

// ---------------------------------------------------------------------------
// Binding parsing / matching
// ---------------------------------------------------------------------------

class ParsedBind
{
    bool shift = false;
    bool ctrl = false;
    bool alt = false;
    string main = "";
}

string NormalizeKeyName(const string &in name)
{
    string l = name.ToLower();
    if (l == "esc") return "escape";
    if (l == "pageup") return "prior";
    if (l == "pagedown") return "next";
    if (l == "del") return "delete";
    if (l == "enter") return "return";
    if (l == "backspace") return "back";
    return l;
}

ParsedBind@ ParseBind(const string &in text)
{
    ParsedBind@ p = ParsedBind();
    auto parts = text.Split("+");

    for (uint i = 0; i < parts.Length; i++)
    {
        string l = parts[i].Trim().ToLower();
        if (l == "shift") p.shift = true;
        else if (l == "ctrl" || l == "control") p.ctrl = true;
        else if (l == "alt") p.alt = true;
        else if (l.Length > 0) p.main = NormalizeKeyName(l);
    }
    return p;
}

bool KeyMatches(const string &in bind, VirtualKey key)
{
    auto p = ParseBind(bind);
    if (p.main.Length == 0)
        return false;
    if (p.shift != g_Shift || p.ctrl != g_Ctrl || p.alt != g_Alt)
        return false;
    return p.main == tostring(key).ToLower();
}

bool SameBind(const string &in a, const string &in b)
{
    auto pa = ParseBind(a);
    auto pb = ParseBind(b);
    return pa.main == pb.main
        && pa.shift == pb.shift
        && pa.ctrl == pb.ctrl
        && pa.alt == pb.alt;
}

string BuildBindString(VirtualKey key)
{
    string s = "";
    if (g_Ctrl) s += "Ctrl+";
    if (g_Shift) s += "Shift+";
    if (g_Alt) s += "Alt+";
    return s + tostring(key);
}

string GetKeyBind(const string &in action)
{
    if (action == "Focus") return Bind_Focus;
    if (action == "Move") return Bind_Move;
    if (action == "Rotate") return Bind_Rotate;
    if (action == "RotateReverse") return Bind_RotateReverse;
    if (action == "Raise") return Bind_Raise;
    if (action == "Lower") return Bind_Lower;
    if (action == "MoveForward") return Bind_MoveForward;
    if (action == "MoveBack") return Bind_MoveBack;
    if (action == "MoveLeft") return Bind_MoveLeft;
    if (action == "MoveRight") return Bind_MoveRight;
    return "";
}

void SetKeyBind(const string &in action, const string &in value)
{
    if (action == "Focus") Bind_Focus = value;
    else if (action == "Move") Bind_Move = value;
    else if (action == "Rotate") Bind_Rotate = value;
    else if (action == "RotateReverse") Bind_RotateReverse = value;
    else if (action == "Raise") Bind_Raise = value;
    else if (action == "Lower") Bind_Lower = value;
    else if (action == "MoveForward") Bind_MoveForward = value;
    else if (action == "MoveBack") Bind_MoveBack = value;
    else if (action == "MoveLeft") Bind_MoveLeft = value;
    else if (action == "MoveRight") Bind_MoveRight = value;
}

string FindKeyConflict(const string &in bind, const string &in exceptAction)
{
    for (uint i = 0; i < g_KeyActions.Length; i++)
    {
        string a = g_KeyActions[i];
        if (a == exceptAction)
            continue;
        if (SameBind(GetKeyBind(a), bind))
            return a;
    }
    return "";
}

void ApplyBlenderDefaults()
{
    PendingOrbit = "MouseRight";
    PendingPan = "MouseMiddle";
    Bind_Orbit = PendingOrbit;
    Bind_Pan = PendingPan;
    Bind_Zoom = "MouseWheel";
    Bind_Select = "MouseLeft";
    Bind_Focus = "F";
    Bind_Move = "G";
    Bind_Rotate = "R";
    Bind_RotateReverse = "Shift+R";
    Bind_Raise = "PageUp";
    Bind_Lower = "PageDown";
    Bind_MoveForward = "W";
    Bind_MoveBack = "";
    Bind_MoveLeft = "A";
    Bind_MoveRight = "D";
    SetStatus("Blender-style defaults restored.");
}

// ---------------------------------------------------------------------------
// Pending mouse bindings (orbit / pan)
// ---------------------------------------------------------------------------

void InitializePendingBindings()
{
    PendingOrbit = Bind_Orbit;
    PendingPan = Bind_Pan;
}

bool HasBindingConflict()
{
    if (PendingOrbit.Length == 0 || PendingPan.Length == 0)
        return true;
    if (PendingOrbit == PendingPan)
        return true;
    // Keep left mouse free for normal map editing.
    if (PendingOrbit == "MouseLeft" || PendingPan == "MouseLeft")
        return true;
    return false;
}

bool HasPendingChanges()
{
    return PendingOrbit != Bind_Orbit || PendingPan != Bind_Pan;
}

void ConfirmPendingBindings()
{
    if (HasBindingConflict())
    {
        SetStatus("Resolve binding conflicts before confirming.");
        return;
    }
    Bind_Orbit = PendingOrbit;
    Bind_Pan = PendingPan;
    SetStatus("Camera bindings saved!");
}

void DiscardPendingBindings()
{
    InitializePendingBindings();
    SetStatus("Pending binding changes discarded.");
}

void StartBindingCapture(const string &in action)
{
    CapturingAction = action;
    IsCapturingBinding = true;
    g_CaptureKeyAction = "";
    SetStatus("Press right or middle mouse to bind " + action + ".");
}

void CancelBindingCapture()
{
    IsCapturingBinding = false;
    CapturingAction = "";
    SetStatus("Binding capture cancelled.");
}

// ---------------------------------------------------------------------------
// Input callbacks
// ---------------------------------------------------------------------------

void BeginOrbit()
{
    auto editor = GetEditor();
    if (editor is null || editor.PluginMapType is null || editor.OrbitalCameraControl is null)
        return;

    auto camera = editor.OrbitalCameraControl;
    g_H = camera.m_CurrentHAngle;
    g_V = camera.m_CurrentVAngle;
    g_PendingH = 0.0f;
    g_PendingV = 0.0f;
    g_Panning = false;
    g_Orbiting = true;
    CancelSmoothCameraFocus();
}

void BeginPan()
{
    auto editor = GetEditor();
    if (editor is null || editor.PluginMapType is null || editor.OrbitalCameraControl is null)
        return;

    g_PanTarget = editor.OrbitalCameraControl.m_TargetedPosition;
    g_PendingPanR = 0.0f;
    g_PendingPanU = 0.0f;
    g_Orbiting = false;
    g_Panning = true;
    CancelSmoothCameraFocus();
}

UI::InputBlocking OnMouseButton(bool down, int button, int x, int y)
{
    // Mouse binding capture (only right / middle are allowed).
    if (IsCapturingBinding)
    {
        if (down && (button == 1 || button == 2))
        {
            string detected = (button == 1) ? "MouseRight" : "MouseMiddle";

            if (CapturingAction == "Orbit")
                PendingOrbit = detected;
            else if (CapturingAction == "Pan")
                PendingPan = detected;

            IsCapturingBinding = false;
            CapturingAction = "";
            SetStatus("Captured " + detected + ". Confirm to save.");
            return UI::InputBlocking::Block;
        }
        return UI::InputBlocking::DoNothing;
    }

    // Openplanet buttons: 0 = left, 1 = right, 2 = middle.
    bool orbitButton =
        (button == 1 && Bind_Orbit == "MouseRight") ||
        (button == 2 && Bind_Orbit == "MouseMiddle");

    bool panButton =
        (button == 1 && Bind_Pan == "MouseRight") ||
        (button == 2 && Bind_Pan == "MouseMiddle");

    if (orbitButton)
    {
        if (down) BeginOrbit();
        else g_Orbiting = false;
    }
    else if (panButton)
    {
        if (down) BeginPan();
        else g_Panning = false;
    }

    return UI::InputBlocking::DoNothing;
}

void OnMouseMove(int x, int y)
{
    vec2 pos = vec2(float(x), float(y));

    if (g_LastMouse.x >= 0.0f && (g_Orbiting || g_Panning))
    {
        float dx = pos.x - g_LastMouse.x;
        float dy = pos.y - g_LastMouse.y;

        if (g_Orbiting)
        {
            float sens = Math::Clamp(OrbitSensitivity, 0.0001f, 0.1f);
            float vy = InvertOrbitY ? -dy : dy;
            g_PendingH -= dx * sens;
            g_PendingV += vy * sens;
        }
        else if (g_Panning)
        {
            float sens = Math::Clamp(PanSensitivity, 0.001f, 5.0f);

            if (ScalePanWithDistance)
            {
                auto editor = GetEditor();
                if (editor !is null && editor.OrbitalCameraControl !is null)
                    sens *= Math::Max(editor.OrbitalCameraControl.m_CameraToTargetDistance, 1.0f) / 64.0f;
            }

            float right = dx * sens;
            float up = -dy * sens;
            if (InvertPanX) right = -right;
            if (InvertPanY) up = -up;

            g_PendingPanR += right;
            g_PendingPanU += up;
        }
    }

    g_LastMouse = pos;
}

UI::InputBlocking OnMouseWheel(int x, int y)
{
    if (Bind_Zoom != "MouseWheel" || y == 0)
        return UI::InputBlocking::DoNothing;
    if (GetPlugin() is null)
        return UI::InputBlocking::DoNothing;

    // Normalize: wheel units differ between systems, so only use the sign.
    float wheel = (y > 0) ? 1.0f : -1.0f;
    if (InvertZoom) wheel = -wheel;

    CancelSmoothCameraFocus();
    ZoomCamera(wheel);
    return UI::InputBlocking::DoNothing;
}

UI::InputBlocking OnKeyPress(bool down, VirtualKey key)
{

    // Modifier tracking.
    if (key == VirtualKey::Shift) { g_Shift = down; return UI::InputBlocking::DoNothing; }
    if (key == VirtualKey::Control) { g_Ctrl = down; return UI::InputBlocking::DoNothing; }
    if (key == VirtualKey::Menu) { g_Alt = down; return UI::InputBlocking::DoNothing; }

    // Key rebinding capture.
    if (g_CaptureKeyAction.Length > 0)
    {
        if (!down)
            return UI::InputBlocking::Block;

        if (key == VirtualKey::Escape)
        {
            g_CaptureKeyAction = "";
            SetStatus("Key capture cancelled.");
            return UI::InputBlocking::Block;
        }

        string bind = BuildBindString(key);
        string conflict = FindKeyConflict(bind, g_CaptureKeyAction);

        if (conflict.Length > 0)
        {
            SetStatus(bind + " is already used by " + conflict + ". Pick another key.");
        }
        else
        {
            SetKeyBind(g_CaptureKeyAction, bind);
            SetStatus(g_CaptureKeyAction + " bound to " + bind + ".");
            g_CaptureKeyAction = "";
        }
        return UI::InputBlocking::Block;
    }

    // Held movement keys need both press and release. Keys are NOT blocked,
    // so typing in game dialogs still works.
    UpdateMoveKeys(key, down);

    if (!down)
        return UI::InputBlocking::DoNothing;

    // Never swallow Escape: it opens the pause menu / exits the editor.
    if (key == VirtualKey::Escape)
        return UI::InputBlocking::DoNothing;

    if (GetPlugin() is null)
        return UI::InputBlocking::DoNothing;

    // Handled keys are blocked so the game doesn't ALSO react to them.
    if (KeyMatches(Bind_Focus, key))
    {
        FocusOnEditorCursor();
        return UI::InputBlocking::Block;
    }
    if (KeyMatches(Bind_Move, key))
    {
        MoveSelection();
        return UI::InputBlocking::Block;
    }
    if (KeyMatches(Bind_Rotate, key))
    {
        RotateCopiedBlocks(true);
        return UI::InputBlocking::Block;
    }
    if (KeyMatches(Bind_RotateReverse, key))
    {
        RotateCopiedBlocks(false);
        return UI::InputBlocking::Block;
    }
    if (KeyMatches(Bind_Raise, key))
    {
        MoveCopyVertically(true);
        return UI::InputBlocking::Block;
    }
    if (KeyMatches(Bind_Lower, key))
    {
        MoveCopyVertically(false);
        return UI::InputBlocking::Block;
    }


    return UI::InputBlocking::DoNothing;
}

// ---------------------------------------------------------------------------
// Per-frame camera update (dt is in milliseconds)
// ---------------------------------------------------------------------------

void Update(float dt)
{
    float s = dt / 1000.0f;

    auto editor = GetEditor();
    if (editor is null || editor.PluginMapType is null || editor.OrbitalCameraControl is null)
    {
        g_Orbiting = false;
        g_Panning = false;
        g_FocusAnimating = false;
        g_CustomActive = false;
        g_KeyForward = false;
        g_KeyBack = false;
        g_KeyLeft = false;
        g_KeyRight = false;
        g_KbActive = false;
        g_MoveVel = vec3(0, 0, 0);
        g_PendingH = 0.0f;
        g_PendingV = 0.0f;
        g_PendingPanR = 0.0f;
        g_PendingPanU = 0.0f;
        return;
    }

    ApplyOrbit(editor, s);
    ApplyPan(editor, s);
    ApplyFocus(editor, s);
    ApplyKeyboardMove(editor, s);

    // Hand control back to Trackmania once everything has settled.
    if (g_CustomActive && !g_Orbiting && !g_Panning && !g_FocusAnimating && !g_KbActive)
    {
        g_IdleMs += dt;
        if (g_IdleMs > 200.0f)
            ReleaseCameraControl();
    }
}

void ApplyOrbit(CGameCtnEditorFree@ editor, float s)
{
    if (Math::Abs(g_PendingH) < 0.00001f && Math::Abs(g_PendingV) < 0.00001f)
        return;

    float f = SmoothFraction(CameraSmoothing, s);
    float maxStep = Math::Max(MaxOrbitStep, 0.001f);

    float stepH = Math::Clamp(g_PendingH * f, -maxStep, maxStep);
    float stepV = Math::Clamp(g_PendingV * f, -maxStep, maxStep);

    g_PendingH -= stepH;
    g_PendingV -= stepV;

    auto camera = editor.OrbitalCameraControl;
    auto plugin = editor.PluginMapType;

    g_H += stepH;
    g_V = Math::Clamp(g_V + stepV, camera.m_MinVAngle, camera.m_MaxVAngle);

    TakeCameraControl(plugin);
    plugin.CameraHAngle = g_H;
    plugin.CameraVAngle = g_V;
}

bool MoveKeyMatches(const string &in bind, VirtualKey key)
{
    auto p = ParseBind(bind);
    return p.main.Length > 0 && p.main == tostring(key).ToLower();
}

void UpdateMoveKeys(VirtualKey key, bool down)
{
    // Releases always clear; presses only count without Ctrl/Alt
    // (so Ctrl+S etc. never move the camera). Shift = move faster.
    bool state = down && EnableWASD && !g_Ctrl && !g_Alt;

    if (MoveKeyMatches(Bind_MoveForward, key)) g_KeyForward = state;
    if (MoveKeyMatches(Bind_MoveBack, key)) g_KeyBack = state;
    if (MoveKeyMatches(Bind_MoveLeft, key)) g_KeyLeft = state;
    if (MoveKeyMatches(Bind_MoveRight, key)) g_KeyRight = state;
}

// Moves the orbit target (and therefore the camera) along the horizontal
// plane. Angles are never touched, so the view direction does not change.
void ApplyKeyboardMove(CGameCtnEditorFree@ editor, float s)
{
    // Don't fight an active mouse pan.
    if (g_Panning)
    {
        g_MoveVel = vec3(0, 0, 0);
        g_KbActive = false;
        return;
    }

    auto camera = editor.OrbitalCameraControl;
    auto plugin = editor.PluginMapType;

    vec3 dir = vec3(0, 0, 0);

    if (EnableWASD)
    {
        float h = camera.m_CurrentHAngle;
        vec3 forward = vec3(Math::Sin(h), 0.0f, Math::Cos(h));
        vec3 right = vec3(-Math::Cos(h), 0.0f, Math::Sin(h));
        if (InvertWASDStrafe)
            right = right * -1.0f;

        if (g_KeyForward) dir = dir + forward;
        if (g_KeyBack) dir = dir - forward;
        if (g_KeyRight) dir = dir + right;
        if (g_KeyLeft) dir = dir - right;
    }

    float len = Math::Sqrt(dir.x * dir.x + dir.z * dir.z);
    bool wantsMove = len > 0.001f;
    if (wantsMove)
        dir = dir * (1.0f / len);

    float velSq = g_MoveVel.x * g_MoveVel.x + g_MoveVel.z * g_MoveVel.z;

    // Nothing pressed and fully slowed down: finished.
    if (!wantsMove && velSq < 0.25f)
    {
        g_MoveVel = vec3(0, 0, 0);
        g_KbActive = false;
        return;
    }

    // Starting a new movement: sync from the real camera target.
    if (!g_KbActive)
    {
        g_KbTarget = camera.m_TargetedPosition;
        g_KbActive = true;
        CancelSmoothCameraFocus();
    }

    float speed = Math::Max(WasdSpeed, 1.0f);
    if (ScalePanWithDistance)
        speed *= Math::Max(camera.m_CameraToTargetDistance, 10.0f) / 64.0f;
    if (g_Shift)
        speed *= 3.0f;

    // Smooth acceleration / deceleration (same smoothing slider as orbit).
    vec3 desired = dir * speed;
    float f = SmoothFraction(CameraSmoothing, s);
    g_MoveVel = g_MoveVel + (desired - g_MoveVel) * f;

    g_KbTarget = g_KbTarget + g_MoveVel * s;

    TakeCameraControl(plugin);
    plugin.CameraTargetPosition = g_KbTarget;
}

void ApplyPan(CGameCtnEditorFree@ editor, float s)
{
    if (Math::Abs(g_PendingPanR) < 0.0001f && Math::Abs(g_PendingPanU) < 0.0001f)
        return;

    float f = SmoothFraction(CameraSmoothing, s);
    float stepR = g_PendingPanR * f;
    float stepU = g_PendingPanU * f;
    g_PendingPanR -= stepR;
    g_PendingPanU -= stepU;

    auto camera = editor.OrbitalCameraControl;
    auto plugin = editor.PluginMapType;

    float h = camera.m_CurrentHAngle;
    float v = camera.m_CurrentVAngle;

    // Screen-right and screen-up vectors for the orbital camera. These are
    // perpendicular to the view direction used by ZoomCamera().
    // If vertical pan feels flipped in game, negate 'up' here.
    vec3 right = vec3(-Math::Cos(h), 0.0f, Math::Sin(h));
    vec3 up = vec3(Math::Sin(v) * Math::Sin(h), Math::Cos(v), Math::Sin(v) * Math::Cos(h));

    g_PanTarget += right * stepR + up * stepU;

    TakeCameraControl(plugin);
    plugin.CameraTargetPosition = g_PanTarget;
}

// ---------------------------------------------------------------------------
// Zoom
// ---------------------------------------------------------------------------

void ZoomCamera(float wheelDelta)
{
    auto editor = GetEditor();
    if (editor is null || editor.PluginMapType is null || editor.OrbitalCameraControl is null)
        return;

    auto plugin = editor.PluginMapType;
    auto camera = editor.OrbitalCameraControl;

    float minimumDistance = 10.0f;
    float closeZoomSpeed = CloseZoomSpeed * ZoomSensitivity;
    float distance = camera.m_CameraToTargetDistance;

    float h = camera.m_CurrentHAngle;
    float v = camera.m_CurrentVAngle;

    vec3 forward = vec3(
        Math::Cos(v) * Math::Sin(h),
        -Math::Sin(v),
        Math::Cos(v) * Math::Cos(h)
    );

    TakeCameraControl(plugin);

    g_KbActive = false;   // keyboard movement re-syncs its target next frame

    // Close range: push the target forward instead of shrinking the distance.
    if (wheelDelta > 0.0f && (distance <= minimumDistance + 0.01f || g_CloseZoomOffset > 0.0f))
    {
        float movement = wheelDelta * closeZoomSpeed;
        plugin.CameraToTargetDistance = minimumDistance;
        plugin.CameraTargetPosition = camera.m_TargetedPosition + forward * movement;
        g_CloseZoomOffset += movement;
        return;
    }

    // Zooming back out of close range.
    if (wheelDelta < 0.0f && g_CloseZoomOffset > 0.0f)
    {
        float movement = Math::Min(-wheelDelta * closeZoomSpeed, g_CloseZoomOffset);
        plugin.CameraToTargetDistance = minimumDistance;
        plugin.CameraTargetPosition = camera.m_TargetedPosition - forward * movement;
        g_CloseZoomOffset -= movement;
        return;
    }

    // Normal orbital zoom.
    float zoomFactor = Math::Pow(1.15f, -wheelDelta * ZoomSensitivity);
    plugin.CameraToTargetDistance = Math::Clamp(distance * zoomFactor, minimumDistance, 5000.0f);
}

// ---------------------------------------------------------------------------
// Focus
// ---------------------------------------------------------------------------

void FocusOnEditorCursor()
{
    auto editor = GetEditor();
    if (editor is null || editor.PluginMapType is null || editor.OrbitalCameraControl is null)
        return;

    auto plugin = editor.PluginMapType;
    vec3 position = plugin.GetVec3FromCoord(plugin.CursorCoord);

    if (SmoothCameraFocus)
    {
        g_FocusTarget = position;
        g_FocusAnimating = true;
        TakeCameraControl(plugin);
        SetStatus("Smooth camera focus started");
    }
    else
    {
        g_FocusAnimating = false;
        TakeCameraControl(plugin);
        plugin.CameraTargetPosition = position;
        SetStatus("Camera focused on editor cursor");
    }
}

void CancelSmoothCameraFocus()
{
    if (!g_FocusAnimating)
        return;
    g_FocusAnimating = false;
    SetStatus("Smooth camera focus interrupted");
}

void ApplyFocus(CGameCtnEditorFree@ editor, float s)
{
    if (!g_FocusAnimating)
        return;

    auto plugin = editor.PluginMapType;
    auto camera = editor.OrbitalCameraControl;

    vec3 current = camera.m_TargetedPosition;
    vec3 difference = g_FocusTarget - current;

    float distance = Math::Sqrt(
        difference.x * difference.x +
        difference.y * difference.y +
        difference.z * difference.z
    );

    if (distance < 0.5f)
    {
        g_FocusAnimating = false;
        SetStatus("Smooth camera focus completed");
        return;   // idle logic in Update() will release control
    }

    float speed = Math::Clamp(FocusTransitionSpeed, 0.5f, 30.0f);
    float factor = SmoothFraction(speed, s);

    TakeCameraControl(plugin);
    plugin.CameraTargetPosition = current + difference * factor;
}

// ---------------------------------------------------------------------------
// Map editing actions
// ---------------------------------------------------------------------------

void MoveSelection()
{
    auto plugin = GetPlugin();
    if (plugin is null)
        return;

    if (plugin.CopyPaste_GetSelectedCoordsCount() == 0)
    {
        SetStatus("No native selection to move");
        return;
    }

    // Cut removes the originals and puts them on the cursor for placement,
    // which is the closest thing to Blender's "grab". Use Undo if you misplace.
    plugin.CopyPaste_Cut();
    SetStatus("Move started (cut). Click to place; Ctrl+Z to undo.");
}

void MoveCopyVertically(bool moveUp)
{
    auto plugin = GetPlugin();
    if (plugin is null || plugin.Cursor is null)
    {
        SetStatus("Editor cursor unavailable");
        return;
    }

    bool success = moveUp ? plugin.Cursor.Raise() : plugin.Cursor.Lower();
    SetStatus(success
        ? (moveUp ? "Copy preview raised" : "Copy preview lowered")
        : "Cursor could not move vertically");
}

void RotateCopiedBlocks(bool clockwise = true)
{
    auto plugin = GetPlugin();
    if (plugin is null || plugin.Cursor is null)
    {
        SetStatus("Editor cursor unavailable");
        return;
    }

    plugin.Cursor.Rotate(clockwise);
    SetStatus("Copy preview rotated");
}

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------

void RenderMenu()
{
    if (UI::MenuItem("Blender Orbit", "", g_ShowWindow))
        g_ShowWindow = !g_ShowWindow;
}

void Render()
{
    if (!g_ShowWindow)
        return;

    if (!UI::Begin("Blender Orbit", g_ShowWindow))
    {
        UI::End();
        return;
    }

    UI::Text("Blender Orbit");
    UI::SameLine();
    UI::TextDisabled("v1.0.0");
    UI::Separator();

    if (UI::Button("Camera")) g_Page = PluginPage::Camera;
    UI::SameLine();
    if (UI::Button("Keybindings")) g_Page = PluginPage::Bindings;
    UI::SameLine();
    if (UI::Button("Diagnostics")) g_Page = PluginPage::Diagnostics;

    UI::Separator();

    if (g_StatusMessage.Length > 0)
    {
        UI::Text(g_StatusMessage);
        UI::Separator();
    }

    if (g_Page == PluginPage::Camera)
        RenderCameraPage();
    else if (g_Page == PluginPage::Bindings)
        RenderBindingsPage();
    else
        RenderDiagnosticsPage();

    UI::End();
}

void RenderCameraPage()
{
    UI::Text("Comfort");
    CameraSmoothing = UI::InputFloat("Smoothing (0 = off)", CameraSmoothing, 1.0f, 2.0f, "%.1f");
    CameraSmoothing = Math::Clamp(CameraSmoothing, 0.0f, 60.0f);
    MaxOrbitStep = UI::InputFloat("Max orbit step / frame (rad)", MaxOrbitStep, 0.005f, 0.01f, "%.3f");
    MaxOrbitStep = Math::Clamp(MaxOrbitStep, 0.005f, 1.0f);

    UI::Separator();
    UI::Text("Sensitivity");
    OrbitSensitivity = UI::InputFloat("Orbit sensitivity", OrbitSensitivity, 0.0005f, 0.001f, "%.4f");
    PanSensitivity = UI::InputFloat("Pan sensitivity", PanSensitivity, 0.005f, 0.01f, "%.3f");
    ScalePanWithDistance = UI::Checkbox("Scale pan with zoom distance", ScalePanWithDistance);
    ZoomSensitivity = UI::InputFloat("Zoom sensitivity", ZoomSensitivity);
    CloseZoomSpeed = UI::InputFloat("Close zoom speed", CloseZoomSpeed);

    UI::Separator();
    UI::Text("Inversion");
    InvertOrbitY = UI::Checkbox("Invert orbit Y", InvertOrbitY);
    InvertPanX = UI::Checkbox("Invert horizontal pan", InvertPanX);
    InvertPanY = UI::Checkbox("Invert vertical pan", InvertPanY);
    InvertZoom = UI::Checkbox("Invert zoom", InvertZoom);

    UI::Separator();
    UI::Text("Keyboard movement (WASD, hold Shift for faster)");
    EnableWASD = UI::Checkbox("Enable WASD movement", EnableWASD);
    WasdSpeed = UI::InputFloat("WASD speed", WasdSpeed, 5.0f, 20.0f, "%.0f");
    WasdSpeed = Math::Clamp(WasdSpeed, 1.0f, 2000.0f);
    InvertWASDStrafe = UI::Checkbox("Swap A/D direction", InvertWASDStrafe);

    UI::Separator();
    UI::Text("Focus");
    SmoothCameraFocus = UI::Checkbox("Smooth camera focus", SmoothCameraFocus);
    FocusTransitionSpeed = UI::InputFloat("Focus transition speed", FocusTransitionSpeed, 0.5f, 1.0f, "%.1f");
    FocusTransitionSpeed = Math::Clamp(FocusTransitionSpeed, 0.5f, 30.0f);

    UI::Separator();
    if (UI::Button("Reset camera settings to defaults"))
        ResetCameraSettings();
}

void ResetCameraSettings()
{
    CameraSmoothing = 14.0f;
    MaxOrbitStep = 0.08f;
    SmoothCameraFocus = true;
    FocusTransitionSpeed = 8.0f;
    OrbitSensitivity = 0.005f;
    PanSensitivity = 0.1f;
    ScalePanWithDistance = true;
    ZoomSensitivity = 1.0f;
    CloseZoomSpeed = 3.0f;
    InvertOrbitY = false;
    InvertPanX = false;
    InvertPanY = false;
    InvertZoom = false;
    EnableWASD = true;
    WasdSpeed = 100.0f;
    InvertWASDStrafe = false;
    SetStatus("Camera settings restored to defaults.");
}

void RenderBindingsPage()
{
    UI::Text("Camera mouse controls");

    UI::Text("Orbit camera");
    if (UI::BeginCombo("##OrbitButton", PendingOrbit))
    {
        if (UI::Selectable("Right mouse", PendingOrbit == "MouseRight")) PendingOrbit = "MouseRight";
        if (UI::Selectable("Middle mouse", PendingOrbit == "MouseMiddle")) PendingOrbit = "MouseMiddle";
        UI::EndCombo();
    }
    if (UI::Button("Capture orbit button"))
        StartBindingCapture("Orbit");

    UI::Text("Pan camera");
    if (UI::BeginCombo("##PanButton", PendingPan))
    {
        if (UI::Selectable("Middle mouse", PendingPan == "MouseMiddle")) PendingPan = "MouseMiddle";
        if (UI::Selectable("Right mouse", PendingPan == "MouseRight")) PendingPan = "MouseRight";
        UI::EndCombo();
    }
    if (UI::Button("Capture pan button"))
        StartBindingCapture("Pan");

    if (IsCapturingBinding)
    {
        UI::Text("Waiting for right or middle mouse: " + CapturingAction);
        if (UI::Button("Cancel capture"))
            CancelBindingCapture();
    }

    UI::Separator();

    if (HasBindingConflict())
    {
        UI::Text("\\$F33CONFLICT: Invalid or duplicate camera binding!");
        UI::Text("\\$F66Orbit and Pan must differ. Left mouse is reserved.");
    }
    else if (HasPendingChanges())
        UI::Text("Changes are pending confirmation.");
    else
        UI::Text("All camera bindings are valid.");

    bool canConfirm = !HasBindingConflict() && HasPendingChanges() && !IsCapturingBinding;
    if (canConfirm)
    {
        if (UI::Button("Confirm bindings"))
            ConfirmPendingBindings();
    }
    else
        UI::TextDisabled("Confirm bindings (disabled)");

    UI::SameLine();
    if (UI::Button("Discard changes"))
        DiscardPendingBindings();

    UI::Text("Active orbit: " + Bind_Orbit + "   Active pan: " + Bind_Pan);
    UI::Text("Zoom: " + Bind_Zoom);

    UI::Separator();
    UI::Text("Keyboard shortcuts (click Rebind, then press the key combo; Esc cancels)");

    for (uint i = 0; i < g_KeyActions.Length; i++)
    {
        string a = g_KeyActions[i];
        UI::Text(a + ": " + GetKeyBind(a));
        UI::SameLine();

        if (g_CaptureKeyAction == a)
        {
            if (UI::Button("Press a key...##" + a))
                g_CaptureKeyAction = "";
        }
        else if (UI::Button("Rebind##" + a))
        {
            g_CaptureKeyAction = a;
            IsCapturingBinding = false;
            SetStatus("Press the key combination for " + a + ".");
        }
    }

    UI::Separator();
    if (UI::Button("Restore Blender-style defaults"))
        ApplyBlenderDefaults();
}

void RenderDiagnosticsPage()
{
    EnableDiagnostic = UI::Checkbox("Enable diagnostic details", EnableDiagnostic);
    UI::Separator();

    if (EnableDiagnostic)
    {
        UI::Text("Orbiting: " + (g_Orbiting ? "yes" : "no"));
        UI::Text("Panning: " + (g_Panning ? "yes" : "no"));
        UI::Text("Plugin owns camera: " + (g_CustomActive ? "yes" : "no"));
        UI::Text("Focus animating: " + (g_FocusAnimating ? "yes" : "no"));
        UI::Text("Close zoom offset: " + g_CloseZoomOffset);
        UI::Text("Modifiers: " + (g_Shift ? "Shift " : "") + (g_Ctrl ? "Ctrl " : "") + (g_Alt ? "Alt" : ""));
        UI::Separator();
    }

    if (UI::Button("Print camera info")) DumpCameraInfo();
    if (UI::Button("Zoom in")) ZoomCamera(1.0f);
    if (UI::Button("Zoom out")) ZoomCamera(-1.0f);
    if (UI::Button("Release camera control")) { ReleaseCameraControl(); SetStatus("Camera control released."); }

    UI::Separator();
    if (UI::Button("Test move (CUT selection)")) MoveSelection();
    if (UI::Button("Rotate copied blocks")) RotateCopiedBlocks(true);
    if (UI::Button("Raise copied blocks")) MoveCopyVertically(true);
    if (UI::Button("Lower copied blocks")) MoveCopyVertically(false);
}

void DumpCameraInfo()
{
    auto editor = GetEditor();
    if (editor is null || editor.OrbitalCameraControl is null)
    {
        SetStatus("No editor camera found.");
        return;
    }

    auto c = editor.OrbitalCameraControl;
    print("=== Blender Orbit camera ===");
    print("H angle: " + c.m_CurrentHAngle + "  V angle: " + c.m_CurrentVAngle);
    print("V limits: " + c.m_MinVAngle + " .. " + c.m_MaxVAngle);
    print("Distance: " + c.m_CameraToTargetDistance);
    print("Target: " + c.m_TargetedPosition.x + ", " + c.m_TargetedPosition.y + ", " + c.m_TargetedPosition.z);
    SetStatus("Camera info printed to the Openplanet log.");
}
