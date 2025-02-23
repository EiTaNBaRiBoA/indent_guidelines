@tool
extends EditorPlugin

signal sig_plugin_disabled
const META_KEY: String = "has_indent_guideline_plugin"

func _enter_tree() -> void:
  #print( "%x" % (Engine.get_version_info().hex) )
  if not Engine.is_editor_hint(): return
  var script_editor: ScriptEditor = EditorInterface.get_script_editor()
  if not script_editor.editor_script_changed.is_connected(_editor_script_changed):
    script_editor.editor_script_changed.connect(_editor_script_changed)
    script_editor.editor_script_changed.emit(script_editor.get_current_script())

func _exit_tree() -> void:
  sig_plugin_disabled.emit()

func _editor_script_changed(_s: Script)->void:
  var script_editor: ScriptEditor = EditorInterface.get_script_editor()
  if not script_editor: return
  var editor_base: ScriptEditorBase = script_editor.get_current_editor()
  if not editor_base: return
  var base_editor: Control = editor_base.get_base_editor()
  if base_editor is CodeEdit:
    var code_edit: CodeEdit = base_editor
    var found: bool = code_edit.get_meta(META_KEY, false)
    if not found:
      code_edit.set_meta(META_KEY, true)
      CodeEditorGuideLine.new(code_edit, sig_plugin_disabled)

#---------------------------------------------

const SETTINGS_4_3: IndentGuidelinesSettings = preload("./Settings_4_3.tres")
const SETTINGS_4_4: IndentGuidelinesSettings = preload("./Settings_4_4.tres")


# Based on https://github.com/godotengine/godot/pull/65757
class CodeEditorGuideLine extends Node:
  
  var SETTINGS: IndentGuidelinesSettings = SETTINGS_4_3 if Engine.get_version_info().hex <= 0x040300 else SETTINGS_4_4

  # Some consts
  const OffsetsFactor: Array[float] = [0.0, 0.5, 1.0]
  const editor_scale: int = 100 # Used to scale values, but almost useless now


  var code_edit: CodeEdit # Reference to CodeEdit
  func _init(p_code_edit: CodeEdit, exit_sig: Signal)-> void:
    code_edit = p_code_edit

    exit_sig.connect(func()->void:
      p_code_edit.remove_meta(META_KEY)
      self.queue_free()
    )

    code_edit.add_child(self)
    code_edit.draw.connect(_draw_appendix)
    code_edit.queue_redraw()
    
    SETTINGS.changed.connect(func()->void:
      print("changed")
      code_edit.queue_redraw()
      )

  # Return value scaled by editor scale
  func scaled(p_val: float)-> float:
    return p_val * (float(editor_scale) / 100.0)

  func _draw_appendix()-> void:
    # Per draw "Consts"
    var lines_count: int = code_edit.get_line_count()
    var style_box: StyleBox = code_edit.get_theme_stylebox("normal")
    var font: Font = code_edit.get_theme_font("font")
    var font_size: int = code_edit.get_theme_font_size("font_size")
    var xmargin_beg: int = style_box.get_margin(SIDE_LEFT) + code_edit.get_total_gutter_width()
    var row_height: int = code_edit.get_line_height()
    var space_width: float = font.get_char_size(" ".unicode_at(0), font_size).x
    var v_scroll: float = code_edit.scroll_vertical
    var h_scroll: float = code_edit.scroll_horizontal

    # X Offset
    var guideline_offset: float = OffsetsFactor[SETTINGS.guideline_drawside] * space_width

    var caret_idx: int = code_edit.get_caret_line()

    # // Let's avoid guidelines out of view.
    var visible_lines_from: int = maxi(code_edit.get_first_visible_line() , 0)
    var visible_lines_to: int = mini(code_edit.get_last_full_visible_line() + int(code_edit.scroll_smooth) + 10, lines_count)

    # V scroll bugged when you fold one of the last block
    var vscroll_delta: float = maxf(v_scroll, visible_lines_from) - visible_lines_from

    # Inlude last ten lines
    if lines_count - visible_lines_to <= 10:
      visible_lines_to = lines_count

    # Generate lines
    var lines_builder: LinesInCodeEditor = LinesInCodeEditor.new(code_edit)
    lines_builder.build(visible_lines_from, visible_lines_to)

    # Prepare draw
    var points: PackedVector2Array
    var colors: PackedColorArray
    var block_ends: PackedInt32Array

    for line: LineInCodeEditor in lines_builder.output:
      var _x: float = xmargin_beg - h_scroll + guideline_offset + line.indent * lines_builder.indent_size * space_width
      # Hide lines under gutters
      if _x < xmargin_beg: continue

      #  Line color
      var color: Color = SETTINGS.guideline_color
      if caret_idx > line.lineno_from and caret_idx <= line.lineno_to and lines_builder.indent_level(caret_idx) == line.indent + 1:
        # TODO: If caret not visible on screen line will not highlighted
        color = SETTINGS.guideline_active_color

      # // Stack multiple guidelines.
      var line_no: int = line.lineno_to
      var offset_y: float = scaled(minf(block_ends.count(line_no) * 2.0, font.get_height(font_size) / 2.0) + 2.0)

      var point_start: Vector2 = Vector2(_x, row_height * (line.start - vscroll_delta) + SETTINGS.guideline_y_offset)
      var point_end: Vector2 = point_start + Vector2(0.0, row_height * line.length - offset_y + SETTINGS.guideline_y_offset)
      points.append_array([point_start, point_end])
      colors.append(color)

      if SETTINGS.guidelines_style == SETTINGS.GuidelinesStyle.LINE_CLOSE and line.close_length > 0:
        #var line_indent: int = lines_builder.indent_level(line_no) + 1
        var point_side: Vector2 = point_end + Vector2(line.close_length * lines_builder.indent_size * space_width - guideline_offset, 0.0)

        points.append_array([point_end, point_side])
        colors.append(color)
        block_ends.append(line_no)

    var rid: RID = code_edit.get_canvas_item()
    # Draw lines
    if points.size() > 0:
      # As documentation said, no need to scale line width
      RenderingServer.canvas_item_add_multiline(rid, points, colors, SETTINGS.guideline_width)

    if SETTINGS.draw_fullheight_line:
      var _x: float = xmargin_beg + SETTINGS.fillheight_x_offset
      RenderingServer.canvas_item_add_line(rid, Vector2(_x, 0), Vector2(_x, code_edit.size.y), SETTINGS.fillheight_line_color, 2.0 )
      pass

    if SETTINGS.draw_foldmarks:
      var _x: float = xmargin_beg + SETTINGS.foldmark_x_offset
      var folded_lines: Array[int] = code_edit.get_folded_lines()

      var fm_points: PackedVector2Array
      var fm_colors: PackedColorArray
      for internal_line: int in lines_builder.foldedlines:
        var point_start: Vector2 = Vector2(_x, row_height * (internal_line - vscroll_delta) + SETTINGS.foldmark_y_offset)
        var point_end: Vector2 = point_start + Vector2(0.0, row_height + SETTINGS.foldmark_y_offset)
        fm_points.append_array([point_start, point_end])
        fm_colors.append(SETTINGS.foldmark_color)
      if fm_points.size() > 0:
        RenderingServer.canvas_item_add_multiline(rid, fm_points, fm_colors, SETTINGS.foldmark_width)
    pass # /_draw_appendix


# Lines builder
class LinesInCodeEditor:
  var output: Array[LineInCodeEditor] = []
  var foldedlines: PackedInt32Array = []

  var ce: CodeEdit
  var indent_size: int
  var lines_count: int

  func _init(p_ce: CodeEdit) -> void:
    self.ce = p_ce
    self.indent_size = p_ce.indent_size

    self.lines_count = p_ce.get_line_count()

    # get indent size from
    for l: int in self.lines_count:
      if self.is_line_empty(l): continue
      if self.is_line_full_commented(l): continue
      var il: int = p_ce.get_indent_level(l)
      if ( il > 0):
        self.indent_size = il
        break

  # Return indent level 0,1,2,3..
  # TODO: invent how not to use `indent_size`
  func indent_level(p_line: int)-> int:
    return ce.get_indent_level(p_line) / self.indent_size

  # Return comment index in line
  # !!!!!!!!! Seems not work like described
  # func get_comment_index(p_line: int)-> int:
  #  return ce.is_in_comment(p_line)

  # Check if line is empty
  func is_line_empty(p_line: int)-> bool:
    #return ce.get_line(p_line).strip_edges().length() == 0
    return ce.get_line(p_line).length() == ce.get_first_non_whitespace_column(p_line)

  # Check if first visible character in line is comment
  func is_line_full_commented(p_line: int)->bool:
    return ce.is_in_comment(p_line) != -1 and ce.get_first_non_whitespace_column(p_line) >= 0

  # Main func
  func build(p_lines_from: int, p_lines_to: int)->void:
    var skiped_lines: int = 0
    var internal_line: int = -1
    var tmp_lines: Array[LineInCodeEditor] = []
    var skip_was_folded: bool = false

    var line: int = p_lines_from

    while line < p_lines_to:
      internal_line += 1

      #If line empty, count it and pass to next line
      var current_line_folded: bool = ce.is_line_folded(line)
      if (is_line_empty(line) or is_line_full_commented(line)) and !current_line_folded :
        skiped_lines += 1
        line += 1
        continue

      var line_indent: int = self.indent_level(line) # Current line indent

      # Close lines with indent > current line_indent
      for i:int in range(line_indent, tmp_lines.size()):
        var v: LineInCodeEditor = tmp_lines[i]
        v.lineno_to = line - skiped_lines - 1
        v.close_length = self.indent_level(v.lineno_to) - v.indent
        if skip_was_folded: v.close_length -= 1 # Decrease indend when skipping folded lines
        output.append(v)

      if line_indent < tmp_lines.size(): tmp_lines.resize(line_indent)

      # Create new line or extend existing
      for i: int in line_indent:
        if tmp_lines.size() - 1 < i: # Create
          var l: LineInCodeEditor = LineInCodeEditor.new()
          # Extend start line up
          l.start = internal_line - skiped_lines
          l.length = 1 + skiped_lines
          l.indent = i
          l.lineno_from = line
          l.lineno_to = line

          tmp_lines.append(l)
        else:
          # Extend existing line
          tmp_lines[i].length += 1 + skiped_lines

      skiped_lines = 0
      # Skip folded lines and regions
      skip_was_folded = current_line_folded
      if skip_was_folded:
        if ce.is_line_code_region_start(line): # Folded region count as ful commented line
          var diff: int = skip_region(line, p_lines_to)
          #skiped_lines += 1
          line += diff
        else:
          foldedlines.append(internal_line) # Store internal folded line
          var diff: int = skip_fold(line, p_lines_to) # Usual fold
          #skiped_lines += 1
          line += diff
      line += 1
    #End of cycle

    # Output all other lines
    for i:int in tmp_lines.size():
      var v: LineInCodeEditor = tmp_lines[i]
      if p_lines_to == self.lines_count:
        v.lineno_to = (p_lines_to - 1) - skiped_lines
        v.close_length = self.indent_level(v.lineno_to) - v.indent
        # v.length += 1 - skiped_lines # At end of file there is bug with lines
      else:
        v.lineno_to = p_lines_to - 1
        v.length += 1
      output.append(v)
      pass

  func skip_fold(line: int, p_lines_to: int) -> int:
    # Usual fold
    var line_indent: int = self.indent_level(line)
    var next_line: int = line
    var subline_found: bool = false
    var skipped_sublines: int = 0
    for subline: int in range(next_line + 1, p_lines_to):
      if is_line_empty(subline):
        skipped_sublines += 1
        continue
      var subline_indent: int = self.indent_level(subline)
      if subline_indent > line_indent:
        skipped_sublines = 0 # Line not empty
        continue
      next_line = subline - skipped_sublines - 1
      subline_found = true
      break # Break for cycle
    if not subline_found: next_line = p_lines_to
    return next_line - line

  func skip_region(line: int, p_lines_to: int) -> int:
    # Folded region
    var next_line: int = line
    var subline_found: bool = false
    for subline: int in range(line + 1, p_lines_to):
      if not ce.is_line_code_region_end(subline): continue
      next_line = subline
      subline_found = true
      break # Break for cycle
    if not subline_found: next_line = p_lines_to
    return next_line - line


# Used as struct representiing line
class LineInCodeEditor:
  var start: int = 0 # Line start X
  var length: int = 1 # Line length from start
  var indent: int = -1 # Line indent
  var lineno_from: int = -1 # Line "from" number in CodeEdit
  var lineno_to: int = -1 # Line "to" number in CodeEdit
  var close_length: int = 0 # Side/Close line length
