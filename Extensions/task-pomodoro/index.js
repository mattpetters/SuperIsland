"use strict";

var PHASE_FOCUS = "focus";
var PHASE_BREAK = "break";

var phase = PHASE_FOCUS;
var isRunning = false;
var remainingSeconds = 0;
var timerID = null;
var sessionsCompleted = 0;
var selectedTaskUUID = "";
var goalCleared = false;
var taskSnapshot = { tasks: [], isRefreshing: false, lastError: "" };
var taskEditorMode = "browse";
var taskSearchQuery = "";
var taskStatusMessage = "";

function toNumber(value, fallback) {
  if (value === null || value === undefined || value === "") return fallback;
  var parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function asObject(value) {
  return value && typeof value === "object" ? value : null;
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function trimString(value) {
  if (value === null || value === undefined) return "";
  return String(value).trim();
}

function renderInputComposer(options) {
  if (SuperIsland.components && typeof SuperIsland.components.inputComposer === "function") {
    return SuperIsland.components.inputComposer(options);
  }

  return View.inputBox(
    options.placeholder || "",
    options.text || "",
    options.action || "",
    {
      id: options.id || "",
      autoFocus: options.autoFocus !== false,
      minHeight: options.minHeight || 46,
      showsEmojiButton: options.showsEmojiButton === true
    }
  );
}

function settingNumber(key, fallback) {
  return toNumber(SuperIsland.settings.get(key), fallback);
}

function settingBool(key, fallback) {
  var value = SuperIsland.settings.get(key);
  if (typeof value === "boolean") return value;
  if (value === null || value === undefined) return fallback;
  if (typeof value === "number") return value !== 0;
  if (typeof value === "string") return value.toLowerCase() === "true";
  return fallback;
}

function focusDurationSeconds() {
  return Math.max(60, Math.floor(settingNumber("workDuration", 25) * 60));
}

function breakDurationSeconds() {
  return Math.max(60, Math.floor(settingNumber("breakDuration", 5) * 60));
}

function currentPhaseDuration() {
  return phase === PHASE_FOCUS ? focusDurationSeconds() : breakDurationSeconds();
}

function formatTime(seconds) {
  var safe = Math.max(0, Math.floor(seconds));
  var m = Math.floor(safe / 60);
  var s = safe % 60;
  return (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s;
}

function todayDateString() {
  var d = new Date();
  return d.getFullYear() + "-" + (d.getMonth() < 9 ? "0" : "") + (d.getMonth() + 1) + "-" + (d.getDate() < 10 ? "0" : "") + d.getDate();
}

function resetSessionsIfNewDay() {
  var storedDate = SuperIsland.store.get("sessionsDate");
  var today = todayDateString();
  if (storedDate !== today) {
    sessionsCompleted = 0;
    SuperIsland.store.set("sessionsCompleted", 0);
    SuperIsland.store.set("sessionsDate", today);
  }
}

function saveState() {
  SuperIsland.store.set("phase", phase);
  SuperIsland.store.set("isRunning", isRunning);
  SuperIsland.store.set("remainingSeconds", remainingSeconds);
  SuperIsland.store.set("sessionsCompleted", sessionsCompleted);
  SuperIsland.store.set("sessionsDate", todayDateString());
  SuperIsland.store.set("selectedTaskUUID", selectedTaskUUID);
  SuperIsland.store.set("goalCleared", goalCleared);
}

function loadState() {
  resetSessionsIfNewDay();
  sessionsCompleted = toNumber(SuperIsland.store.get("sessionsCompleted"), 0);
  var storedPhase = SuperIsland.store.get("phase");
  phase = storedPhase === PHASE_BREAK ? PHASE_BREAK : PHASE_FOCUS;
  var storedRemaining = toNumber(SuperIsland.store.get("remainingSeconds"), currentPhaseDuration());
  remainingSeconds = Math.max(0, Math.min(storedRemaining, currentPhaseDuration()));
  var storedRunning = SuperIsland.store.get("isRunning");
  isRunning = typeof storedRunning === "boolean" ? storedRunning : false;
  selectedTaskUUID = trimString(SuperIsland.store.get("selectedTaskUUID"));
  goalCleared = SuperIsland.store.get("goalCleared") === true;
  if (remainingSeconds <= 0) remainingSeconds = currentPhaseDuration();
}

function taskGoalEnabled() {
  return settingBool("taskGoalEnabled", true);
}

function showProject() {
  return settingBool("showProject", true);
}

function readTaskSnapshot(forceRefresh, query, includeCompleted) {
  if (!taskGoalEnabled()) return;
  if (!SuperIsland.system || typeof SuperIsland.system.getTaskwarriorTasks !== "function") {
    taskSnapshot = { tasks: [], isRefreshing: false, lastError: "Taskwarrior bridge unavailable." };
    return;
  }

  var effectiveQuery = trimString(query);
  var shouldIncludeCompleted = includeCompleted === true || !!selectedTaskUUID || taskEditorMode === "search";
  var payload = asObject(SuperIsland.system.getTaskwarriorTasks(!!forceRefresh, effectiveQuery, shouldIncludeCompleted));
  if (!payload) return;
  taskSnapshot = {
    tasks: asArray(payload.tasks),
    isRefreshing: payload.isRefreshing === true,
    lastError: trimString(payload.lastError)
  };

  if (!goalCleared && !selectedTaskUUID && taskSnapshot.tasks.length > 0) {
    selectedTaskUUID = trimString(taskSnapshot.tasks[0].uuid) || String(taskSnapshot.tasks[0].id || "");
    saveState();
  }
}

function taskKey(task) {
  return trimString(task && task.uuid) || String(task && task.id || "");
}

function taskStatus(task) {
  return trimString(task && task.status) || "pending";
}

function isTaskCompleted(task) {
  return taskStatus(task) === "completed";
}

function pendingTasks() {
  return (taskSnapshot.tasks || []).filter(function(task) { return !isTaskCompleted(task); });
}

function selectedTaskIndex() {
  var tasks = taskSnapshot.tasks || [];
  if (!tasks.length || !selectedTaskUUID) return -1;
  for (var i = 0; i < tasks.length; i += 1) {
    if (taskKey(tasks[i]) === selectedTaskUUID) return i;
  }
  return -1;
}

function selectedTask() {
  if (!taskGoalEnabled() || goalCleared) return null;
  var tasks = taskSnapshot.tasks || [];
  if (!tasks.length) return null;
  var index = selectedTaskIndex();
  if (index >= 0) return tasks[index];
  return null;
}

function selectTaskOffset(offset) {
  readTaskSnapshot(false);
  var tasks = pendingTasks();
  if (!tasks.length) return;
  var index = -1;
  for (var i = 0; i < tasks.length; i += 1) {
    if (taskKey(tasks[i]) === selectedTaskUUID) {
      index = i;
      break;
    }
  }
  if (index < 0) index = 0;
  index = (index + offset + tasks.length) % tasks.length;
  selectedTaskUUID = taskKey(tasks[index]);
  goalCleared = false;
  saveState();
}

function selectTask(task) {
  if (!task) return;
  selectedTaskUUID = taskKey(task);
  goalCleared = false;
  taskEditorMode = "browse";
  taskStatusMessage = "";
  saveState();
}

function clearTaskGoal() {
  selectedTaskUUID = "";
  goalCleared = true;
  saveState();
}

function taskGoalTitle() {
  var task = selectedTask();
  var title = trimString(task && task.description);
  return title || "";
}

function taskGoalMeta() {
  var task = selectedTask();
  if (!task) return "";
  var parts = [];
  var project = trimString(task.project);
  var priority = trimString(task.priority);
  if (isTaskCompleted(task)) parts.push("Done");
  if (showProject() && project) parts.push(project);
  if (priority) parts.push("P" + priority);
  return parts.join(" · ");
}

function applyTaskMutationResult(payload, successMessage) {
  var result = asObject(payload);
  if (!result) {
    taskStatusMessage = "Taskwarrior did not return a result.";
    SuperIsland.playFeedback("error");
    return false;
  }

  var snapshot = asObject(result.snapshot);
  if (snapshot) {
    taskSnapshot = {
      tasks: asArray(snapshot.tasks),
      isRefreshing: snapshot.isRefreshing === true,
      lastError: trimString(snapshot.lastError)
    };
  }

  if (result.ok === true) {
    taskStatusMessage = successMessage || "";
    SuperIsland.playFeedback("success");
    return true;
  }

  taskStatusMessage = trimString(result.error) || "Taskwarrior command failed.";
  SuperIsland.playFeedback("error");
  return false;
}

function completeSelectedTask() {
  var task = selectedTask();
  var identifier = taskKey(task);
  if (!identifier || !SuperIsland.system || typeof SuperIsland.system.completeTaskwarriorTask !== "function") return;
  applyTaskMutationResult(SuperIsland.system.completeTaskwarriorTask(identifier), "Marked complete");
}

function uncompleteSelectedTask() {
  var task = selectedTask();
  var identifier = taskKey(task);
  if (!identifier || !SuperIsland.system || typeof SuperIsland.system.uncompleteTaskwarriorTask !== "function") return;
  applyTaskMutationResult(SuperIsland.system.uncompleteTaskwarriorTask(identifier), "Restored to pending");
}

function submitTaskRename(description) {
  var task = selectedTask();
  var identifier = taskKey(task);
  if (!identifier || !SuperIsland.system || typeof SuperIsland.system.renameTaskwarriorTask !== "function") return;
  if (applyTaskMutationResult(SuperIsland.system.renameTaskwarriorTask(identifier, description), "Renamed task")) {
    taskEditorMode = "browse";
  }
}

function submitTaskCreate(description) {
  if (!SuperIsland.system || typeof SuperIsland.system.createTaskwarriorTask !== "function") return;
  if (applyTaskMutationResult(SuperIsland.system.createTaskwarriorTask(description), "Created task")) {
    var normalized = trimString(description).toLowerCase();
    var tasks = taskSnapshot.tasks || [];
    for (var i = 0; i < tasks.length; i += 1) {
      if (!isTaskCompleted(tasks[i]) && trimString(tasks[i].description).toLowerCase() === normalized) {
        selectedTaskUUID = taskKey(tasks[i]);
        goalCleared = false;
        break;
      }
    }
    taskEditorMode = "browse";
    saveState();
  }
}

function stopTimer() {
  if (timerID !== null) {
    clearInterval(timerID);
    timerID = null;
  }
}

function startTimer() {
  if (timerID !== null) return;
  timerID = setInterval(function() { tick(); }, 1000);
}

function isFullExpanded() {
  return SuperIsland.island.state === "fullExpanded";
}

function revealIsland() {
  if (isFullExpanded()) return;
  var revealSettleDelay = 120;
  var visibleDuration = 2000;
  SuperIsland.island.activate(false);
  setTimeout(function() { SuperIsland.island.activate(false); }, revealSettleDelay);
  setTimeout(function() { SuperIsland.island.dismiss(); }, visibleDuration + revealSettleDelay);
}

function setRunning(nextRunning) {
  isRunning = nextRunning;
  if (isRunning) startTimer();
  else stopTimer();
  updateMascotExpression();
  saveState();
}

function updateMascotExpression() {
  if (!isRunning || phase === PHASE_BREAK) {
    SuperIsland.mascot.setExpression("idle");
    return;
  }
  SuperIsland.mascot.setExpression("working");
}

function switchPhase() {
  var wasFocus = phase === PHASE_FOCUS;
  if (wasFocus) {
    sessionsCompleted += 1;
    SuperIsland.store.set("sessionsCompleted", sessionsCompleted);
  }
  phase = wasFocus ? PHASE_BREAK : PHASE_FOCUS;
  remainingSeconds = currentPhaseDuration();
  if (settingBool("notifyOnComplete", true)) {
    var goal = taskGoalTitle();
    SuperIsland.notifications.send({
      title: wasFocus ? "Break started" : "Break ended",
      body: wasFocus
        ? "Session " + sessionsCompleted + " complete" + (goal ? ": " + goal : "") + "."
        : "Break ended. Start your next focus session when ready.",
      sound: settingBool("playSound", true)
    });
  }
  SuperIsland.playFeedback("success");
  if (wasFocus) setRunning(true);
  else setRunning(false);
  revealIsland();
  updateMascotExpression();
  saveState();
}

function tick() {
  if (!isRunning) return;
  resetSessionsIfNewDay();
  remainingSeconds -= 1;
  if (remainingSeconds <= 0) {
    remainingSeconds = 0;
    switchPhase();
    return;
  }
  if (remainingSeconds % 15 === 0) saveState();
}

function resetToFocus() {
  phase = PHASE_FOCUS;
  remainingSeconds = focusDurationSeconds();
  setRunning(false);
  saveState();
}

function skipPhase() {
  switchPhase();
}

function progressRatio() {
  return 1 - remainingSeconds / Math.max(1, currentPhaseDuration());
}

function phaseIcon() {
  if (phase === PHASE_BREAK) return "cup.and.saucer.fill";
  if (remainingSeconds <= 60 && isRunning) return "flame.fill";
  return taskGoalTitle() ? "checklist" : "brain.head.profile";
}

function phaseColor() {
  if (phase === PHASE_BREAK) return "green";
  if (remainingSeconds <= 60 && isRunning) return "red";
  return "white";
}

function progressColor() {
  return phase === PHASE_BREAK ? "green" : phaseColor();
}

function avatarSymbol() {
  if (phase === PHASE_BREAK) return isRunning ? "cup.and.saucer.fill" : "leaf.fill";
  if (!isRunning) return taskGoalTitle() ? "checklist" : "moon.zzz.fill";
  if (remainingSeconds <= 60) return "flame.fill";
  return taskGoalTitle() ? "target" : "brain.head.profile.fill";
}

function avatarAnim() {
  if (!isRunning) return null;
  if (phase === PHASE_BREAK) return "bounce";
  if (remainingSeconds <= 60) return "blink";
  return "pulse";
}

function statusLabel() {
  if (phase === PHASE_BREAK) return isRunning ? "Chilling" : "Resting";
  if (isRunning) return remainingSeconds <= 60 ? "Wrapping up!" : "Deep work";
  return taskGoalTitle() ? "Ready for task" : "Ready to focus";
}

function ac() {
  if (phase === PHASE_BREAK) return { r: 0.4, g: 0.87, b: 0.55, a: 1 };
  if (remainingSeconds <= 60 && isRunning) return { r: 1, g: 0.4, b: 0.35, a: 1 };
  return { r: 1, g: 0.68, b: 0.26, a: 1 };
}

function coloredCircle(size, color) {
  return View.cornerRadius(
    View.background(
      View.frame(View.text("", { style: "caption", color: "white" }), { width: size, height: size }),
      color
    ),
    size / 2
  );
}

function buildAvatarOrb(size, animationKind) {
  var orbSize = size || 60;
  var glowSize = orbSize;
  var midSize = orbSize * 0.8;
  var coreSize = orbSize * 0.63;
  var iconSize = orbSize * 0.43;
  var c = ac();
  var iconView = View.icon(avatarSymbol(), {
    size: iconSize,
    color: { r: Math.min(1, c.r + 0.15), g: Math.min(1, c.g + 0.15), b: Math.min(1, c.b + 0.15), a: 1 }
  });
  var anim = animationKind === undefined ? avatarAnim() : animationKind;
  return View.zstack([
    coloredCircle(glowSize, { r: c.r, g: c.g, b: c.b, a: 0.12 }),
    coloredCircle(midSize, { r: c.r * 0.2, g: c.g * 0.2, b: c.b * 0.2, a: 0.8 }),
    coloredCircle(coreSize, { r: c.r * 0.3, g: c.g * 0.3, b: c.b * 0.3, a: 1 }),
    anim ? View.animate(iconView, anim) : iconView
  ]);
}

function controlBtn(iconName, actionID, size, primary) {
  if (primary) {
    return View.button(
      View.cornerRadius(
        View.background(
          View.frame(View.icon(iconName, { size: size, color: "white" }), { width: 46, height: 46 }),
          ac()
        ),
        23
      ),
      actionID
    );
  }
  return View.button(
    View.icon(iconName, { size: size, color: { r: 1, g: 1, b: 1, a: 0.5 } }),
    actionID
  );
}

function goalLineView(style, alignment) {
  var goal = taskGoalTitle();
  var meta = taskGoalMeta();
  var error = trimString(taskStatusMessage) || trimString(taskSnapshot.lastError);
  var align = alignment || "leading";
  if (goal) {
    return View.vstack([
      View.text(goal, { style: style || "footnote", color: "white", lineLimit: 1 }),
      meta ? View.text(meta, { style: "caption", color: { r: 1, g: 1, b: 1, a: 0.45 }, lineLimit: 1 }) : null
    ], { spacing: 2, align: align });
  }
  if (taskGoalEnabled() && error) {
    return View.text(error, { style: "footnote", color: { r: 1, g: 0.55, b: 0.45, a: 1 }, lineLimit: 2 });
  }
  return View.text(taskGoalEnabled() ? "No task goal selected" : "Task goal off", {
    style: "footnote",
    color: { r: 1, g: 1, b: 1, a: 0.4 },
    lineLimit: 1
  });
}

function taskControlsView() {
  var task = selectedTask();
  var canEdit = !!task;
  var done = isTaskCompleted(task);
  return View.hstack([
    View.button(View.icon("arrow.clockwise", { size: 12, color: { r: 1, g: 1, b: 1, a: 0.55 } }), "task-refresh"),
    View.button(View.icon("chevron.left", { size: 12, color: { r: 1, g: 1, b: 1, a: 0.55 } }), "task-prev"),
    View.button(View.icon("magnifyingglass", { size: 12, color: { r: 1, g: 1, b: 1, a: 0.55 } }), "task-search"),
    View.button(View.icon("plus", { size: 12, color: { r: 1, g: 1, b: 1, a: 0.62 } }), "task-create"),
    canEdit ? View.button(View.icon("pencil", { size: 12, color: { r: 1, g: 1, b: 1, a: 0.55 } }), "task-rename") : null,
    canEdit ? View.button(View.icon(done ? "arrow.uturn.backward.circle" : "checkmark.circle", { size: 12, color: done ? "orange" : "green" }), "task-toggle-complete") : null,
    View.button(View.icon("xmark", { size: 12, color: { r: 1, g: 1, b: 1, a: 0.55 } }), "task-clear"),
    View.button(View.icon("chevron.right", { size: 12, color: { r: 1, g: 1, b: 1, a: 0.55 } }), "task-next")
  ], { spacing: 10, align: "center" });
}

function taskSuggestionRow(task, index) {
  var title = trimString(task.description) || "(untitled task)";
  var meta = [];
  if (isTaskCompleted(task)) meta.push("Done");
  if (trimString(task.project)) meta.push(trimString(task.project));
  if (trimString(task.priority)) meta.push("P" + trimString(task.priority));
  return View.button(
    View.hstack([
      View.icon(isTaskCompleted(task) ? "checkmark.circle.fill" : "circle", {
        size: 10,
        color: isTaskCompleted(task) ? "green" : { r: 1, g: 1, b: 1, a: 0.42 }
      }),
      View.frame(
        View.vstack([
          View.text(title, { style: "footnote", color: "white", lineLimit: 1 }),
          meta.length ? View.text(meta.join(" · "), { style: "footnote", color: { r: 1, g: 1, b: 1, a: 0.42 }, lineLimit: 1 }) : null
        ], { spacing: 1, align: "leading" }),
        { maxWidth: 9999, alignment: "leading" }
      )
    ], { spacing: 6, align: "center" }),
    "task-select-" + index
  );
}

function taskSearchView() {
  readTaskSnapshot(false, taskSearchQuery, true);
  var tasks = (taskSnapshot.tasks || []).slice(0, 5);
  var rows = tasks.map(function(task, index) { return taskSuggestionRow(task, index); });
  return View.vstack([
    View.hstack([
      View.text("Find task", { style: "caption", color: { r: 1, g: 1, b: 1, a: 0.58 }, lineLimit: 1 }),
      View.spacer(),
      View.button(View.icon("xmark", { size: 11, color: { r: 1, g: 1, b: 1, a: 0.5 } }), "task-mode-browse")
    ], { spacing: 6, align: "center" }),
    renderInputComposer({
      placeholder: "Search by task, project, tag",
      text: taskSearchQuery,
      action: "task-submit-search",
      id: "task-search",
      autoFocus: true,
      minHeight: 38,
      showsShortcutHint: false,
      chrome: false,
      spacing: 1
    }),
    rows.length ? View.vstack(rows, { spacing: 4, align: "leading" }) : View.text("No matches", {
      style: "footnote",
      color: { r: 1, g: 1, b: 1, a: 0.38 },
      lineLimit: 1
    })
  ], { spacing: 6, align: "leading" });
}

function taskCreateView() {
  return View.vstack([
    View.hstack([
      View.text("New task", { style: "caption", color: { r: 1, g: 1, b: 1, a: 0.58 }, lineLimit: 1 }),
      View.spacer(),
      View.button(View.icon("xmark", { size: 11, color: { r: 1, g: 1, b: 1, a: 0.5 } }), "task-mode-browse")
    ], { spacing: 6, align: "center" }),
    renderInputComposer({
      placeholder: "Task description",
      text: "",
      action: "task-submit-create",
      id: "task-create",
      autoFocus: true,
      minHeight: 38,
      showsShortcutHint: false,
      chrome: false,
      spacing: 1
    })
  ], { spacing: 6, align: "leading" });
}

function taskRenameView() {
  var task = selectedTask();
  return View.vstack([
    View.hstack([
      View.text("Rename task", { style: "caption", color: { r: 1, g: 1, b: 1, a: 0.58 }, lineLimit: 1 }),
      View.spacer(),
      View.button(View.icon("xmark", { size: 11, color: { r: 1, g: 1, b: 1, a: 0.5 } }), "task-mode-browse")
    ], { spacing: 6, align: "center" }),
    renderInputComposer({
      placeholder: "Task description",
      text: taskGoalTitle(),
      action: "task-submit-rename",
      id: "task-rename-" + taskKey(task),
      autoFocus: true,
      minHeight: 38,
      showsShortcutHint: false,
      chrome: false,
      spacing: 1
    })
  ], { spacing: 6, align: "leading" });
}

function taskEditorPanel() {
  if (taskEditorMode === "search") return taskSearchView();
  if (taskEditorMode === "create") return taskCreateView();
  if (taskEditorMode === "rename") return taskRenameView();
  return View.vstack([
    goalLineView("footnote", "trailing"),
    taskControlsView()
  ], { spacing: 7, align: "trailing" });
}

SuperIsland.registerModule({
  onActivate: function() {
    loadState();
    readTaskSnapshot(true);
    if (isRunning) startTimer();
    updateMascotExpression();
  },

  onDeactivate: function() {
    stopTimer();
    isRunning = false;
    saveState();
  },

  onSettingsChanged: function(key) {
    if (key === "taskGoalEnabled") readTaskSnapshot(true);
  },

  onAction: function(actionID, value) {
    if (actionID && actionID.indexOf("task-select-") === 0) {
      var selectIndex = Number(actionID.slice("task-select-".length));
      var task = (taskSnapshot.tasks || [])[selectIndex];
      selectTask(task);
      return;
    }

    switch (actionID) {
      case "toggle":
        setRunning(!isRunning);
        if (isRunning) revealIsland();
        break;
      case "reset":
        resetToFocus();
        break;
      case "skip":
        skipPhase();
        break;
      case "task-refresh":
        readTaskSnapshot(true, taskEditorMode === "search" ? taskSearchQuery : "", taskEditorMode === "search");
        break;
      case "task-prev":
        selectTaskOffset(-1);
        break;
      case "task-next":
        selectTaskOffset(1);
        break;
      case "task-clear":
        clearTaskGoal();
        break;
      case "task-search":
        taskEditorMode = "search";
        taskStatusMessage = "";
        readTaskSnapshot(true, taskSearchQuery, true);
        break;
      case "task-create":
        taskEditorMode = "create";
        taskStatusMessage = "";
        break;
      case "task-rename":
        if (selectedTask()) {
          taskEditorMode = "rename";
          taskStatusMessage = "";
        }
        break;
      case "task-toggle-complete":
        if (isTaskCompleted(selectedTask())) uncompleteSelectedTask();
        else completeSelectedTask();
        break;
      case "task-mode-browse":
        taskEditorMode = "browse";
        taskStatusMessage = "";
        break;
      case "task-submit-search":
        taskSearchQuery = trimString(value);
        readTaskSnapshot(true, taskSearchQuery, true);
        break;
      case "task-submit-create":
        submitTaskCreate(value);
        break;
      case "task-submit-rename":
        submitTaskRename(value);
        break;
    }
  },

  compact: function() {
    readTaskSnapshot(false);
    return View.hstack([
      View.icon(phaseIcon(), { size: 12, color: phaseColor() }),
      View.text(formatTime(remainingSeconds), { style: "monospaced", color: "white" }),
      isRunning ? View.circularProgress(progressRatio(), { total: 1, lineWidth: 2, color: progressColor() }) : null
    ], { spacing: 6, align: "center" });
  },

  minimalCompact: {
    leading: function() {
      return View.frame(View.mascot({ size: 28 }), { width: 28, height: 28, alignment: "center" });
    },
    trailing: function() {
      return View.text(formatTime(remainingSeconds), { style: "monospacedSmall", color: "white" });
    },
    precedence: function() {
      return isRunning ? 1 : 0;
    }
  },

  expanded: function() {
    readTaskSnapshot(false);
    return View.hstack([
      View.mascot({ size: 50 }),
      View.vstack([
        View.text(phase === PHASE_FOCUS ? "Focus" : "Break", { style: "title", color: "white" }),
        View.text(formatTime(remainingSeconds), { style: "monospaced", color: "white" }),
        goalLineView("footnote")
      ], { spacing: 3, align: "leading" }),
      View.spacer(),
      View.button(View.icon(isRunning ? "pause.fill" : "play.fill", { size: 16, color: "white" }), "toggle")
    ], { spacing: 10, align: "center" });
  },

  fullExpanded: function() {
    readTaskSnapshot(false);
    var ratio = progressRatio();
    var a = ac();
    var time = formatTime(remainingSeconds);
    var label = statusLabel();
    var minsLeft = Math.ceil(remainingSeconds / 60);
    var leftPanel = View.frame(View.mascot({ size: 116 }), { width: 132, maxHeight: 9999, alignment: "center" });

    var timerPanel = View.frame(
      View.vstack([
        View.text(time, { style: "largeTitle", color: "white" }),
        View.text(label, { style: "caption", color: a })
      ], { spacing: 1, align: "leading" }),
      { width: 146, alignment: "leading" }
    );

    var taskPanel = View.frame(
      taskEditorPanel(),
      { maxWidth: 9999, alignment: "trailing" }
    );

    var transportPanel = View.frame(
      View.hstack([
        controlBtn("arrow.counterclockwise", "reset", 15, false),
        controlBtn(isRunning ? "pause.fill" : "play.fill", "toggle", 18, true),
        controlBtn("forward.fill", "skip", 15, false)
      ], { spacing: 18, align: "center" }),
      { width: 146, alignment: "center" }
    );

    var rightPanel = View.vstack([
      View.hstack([
        timerPanel,
        View.spacer(),
        taskPanel
      ], { spacing: 18, align: "top" }),

      View.progress(ratio, { total: 1, color: a }),

      View.hstack([
        View.text(phase === PHASE_FOCUS ? "Focus" : "Break", { style: "footnote", color: { r: 1, g: 1, b: 1, a: 0.35 } }),
        View.spacer(),
        View.text(minsLeft + "m left", { style: "footnote", color: { r: 1, g: 1, b: 1, a: 0.35 } })
      ], { spacing: 4, align: "center" }),

      View.hstack([
        transportPanel,
        View.spacer(),
        View.icon("checkmark.circle.fill", { size: 9, color: a }),
        View.text(sessionsCompleted + "", { style: "caption", color: { r: 1, g: 1, b: 1, a: 0.4 } })
      ], { spacing: 14, align: "center" })
    ], { spacing: 7, align: "leading" });

    return View.hstack([
      leftPanel,
      View.frame(rightPanel, { maxWidth: 9999, maxHeight: 9999 })
    ], { spacing: 12, align: "center" });
  }
});
