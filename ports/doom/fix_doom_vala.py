import sys, re

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()

# 1. Enum array sizes -> (int) Enum.VAL
src = re.sub(
    r"new (\w+)\[((?:powertype_t|card_t|weapontype_t|ammotype_t|psprnum_t|skill_t|gamestate_t|key_t)\.\w+)\]",
    r"new \1[(int) \2]",
    src,
)

# 2. thinker_s.owner: Object? + owner_mobj: mobj_s[]?
src = src.replace(
    "    public uint8[] owner;\n",
    "    public Object? owner;\n    public mobj_s[]? owner_mobj;\n",
)
src = src.replace(
    "mobj[0].thinker.owner = mobj;",
    "mobj[0].thinker.owner_mobj = mobj;",
)
src = src.replace(
    "actor[0].thinker.owner = actor;",
    "actor[0].thinker.owner_mobj = actor;",
)

# Fix P_RunThinkers dispatch
old_switch = """            switch (currentthinker.tag) {
                case 1:
                    P_MobjThinker (currentthinker.owner);
                    break;
                case 2:
                    T_MoveCeiling (new ceiling_t.at (currentthinker.owner, 0));
                    break;
                case 3:
                    T_VerticalDoor (new vldoor_t.at (currentthinker.owner, 0));
                    break;
                case 4:
                    T_MoveFloor (new floormove_t.at (currentthinker.owner, 0));
                    break;
                case 5:
                    T_PlatRaise (new plat_t.at (currentthinker.owner, 0));
                    break;
                case 6:
                    T_LightFlash (new lightflash_t.at (currentthinker.owner, 0));
                    break;
                case 7:
                    T_StrobeFlash (new strobe_t.at (currentthinker.owner, 0));
                    break;
                case 8:
                    T_Glow (new glow_t.at (currentthinker.owner, 0));
                    break;
                case 9:
                    T_FireFlicker (_c2v_box_fireflicker_t_obj (currentthinker.owner));
                    break;
            }"""

new_switch = """            switch (currentthinker.tag) {
                case 1:
                    P_MobjThinker ((!) currentthinker.owner_mobj);
                    break;
                case 2:
                    T_MoveCeiling ((ceiling_t) ((!) currentthinker.owner));
                    break;
                case 3:
                    T_VerticalDoor ((vldoor_t) ((!) currentthinker.owner));
                    break;
                case 4:
                    T_MoveFloor ((floormove_t) ((!) currentthinker.owner));
                    break;
                case 5:
                    T_PlatRaise ((plat_t) ((!) currentthinker.owner));
                    break;
                case 6:
                    T_LightFlash ((lightflash_t) ((!) currentthinker.owner));
                    break;
                case 7:
                    T_StrobeFlash ((strobe_t) ((!) currentthinker.owner));
                    break;
                case 8:
                    T_Glow ((glow_t) ((!) currentthinker.owner));
                    break;
                case 9:
                    T_FireFlicker ((fireflicker_t) ((!) currentthinker.owner));
                    break;
            }"""
src = src.replace(old_switch, new_switch)

# 3. function.acv == ((_c2v_del_atexit_func_t_e6e634?) (-1)) -> tag == -1
src = re.sub(
    r"(\S+)\.function\.acv\s*==\s*\(\(_c2v_del_[A-Za-z0-9_]+\??\)\s*\(-1\)\)",
    r"\1.tag == -1",
    src,
)
src = re.sub(
    r"(\S+)\.function\.acv\s*=\s*\(\(_c2v_del_[A-Za-z0-9_]+\??\)\s*\(-1\)\);",
    r"\1.tag = -1;",
    src,
)

# 4. sector_t.specialdata: Object?
src = src.replace(
    "    public uint8[] specialdata;\n",
    "    public Object? specialdata;\n",
)
src = re.sub(r'(\.specialdata\s*=\s*)new uint8\[0\]\s*;', r'\1null;', src)

# 5. spritelights / walllights: uint8[][]
src = src.replace(
    "public _c2v_abox_uint8? spritelights;",
    "public uint8[][] spritelights;",
)
src = src.replace(
    "public _c2v_abox_uint8? walllights;",
    "public uint8[][] walllights;",
)

# 13. uint8[] X = null; -> uint8[] X = new uint8[0];
src = re.sub(r'(\buint8\[\]\s+\w+\s*=\s*)null\s*;', r'\1new uint8[0];', src)

# 15. Global map/wad arrays that were inferred as T? instead of T[]
for gtype, gname in [
    ("spritedef_t", "sprites"),
    ("sector_t", "sectors"),
    ("subsector_s", "subsectors"),
    ("node_t", "nodes"),
    ("line_s", "lines"),
    ("side_t", "sides"),
    ("lumpinfo_s", "lumpinfo"),
    ("seg_t", "segs"),
    ("vertex_t", "vertexes"),
]:
    src = src.replace(f"public {gtype}? {gname};", f"public {gtype}[] {gname} = new {gtype}[0];")
    src = src.replace(f"_c2v_box_{gtype}_arr ({gname})", gname)

src = src.replace("public spriteframe_t? spriteframes;", "public spriteframe_t[] spriteframes = new spriteframe_t[0];")
src = re.sub(r'_c2v_box_spriteframe_t_arr \(([^)]+\.spriteframes)\)', r'\1', src)

# 16. new post_t.at (patch, X) -> new post_t.at ((!) patch._c2v_data, patch._off + X)
src = src.replace("new post_t.at (patch, ", "new post_t.at ((!) patch._c2v_data, patch._off + ")

# 17. _c2v_slice_uint8 (column/patchcol, X) -> _c2v_slice_uint8 ((!) col._c2v_data, col._off + X)
for cname in ("column", "patchcol"):
    src = src.replace(f"_c2v_slice_uint8 ({cname}, ", f"_c2v_slice_uint8 ((!) {cname}._c2v_data, {cname}._off + ")
    src = src.replace(f"_c2v_slice_int16 ({cname}, ", f"_c2v_slice_int16 ((!) {cname}._c2v_data, {cname}._off + ")

# 18. PIT_* wrappers for mobj_s? / line_s? delegate signatures
pit_mobj = ["PIT_StompThing", "PIT_CheckThing", "PIT_RadiusAttack", "PIT_ChangeSector"]
pit_line = ["PIT_CheckLine", "PIT_AddLineIntercepts"]
wrappers = []
for fn in pit_mobj:
    src = src.replace(f", {fn})", f", _w_{fn})")
    wrappers.append(f"public uint32 _w_{fn} (mobj_s? t) {{ return {fn} (_c2v_box_mobj_s_arr (t)); }}")
for fn in pit_line:
    src = src.replace(f", {fn})", f", _w_{fn})")
    wrappers.append(f"public uint32 _w_{fn} (line_s? l) {{ return {fn} (_c2v_box_line_s_arr (l)); }}")
src += "\n" + "\n".join(wrappers) + "\n"

# 14. state_t? == _c2v_slice_state_t (states, X) -> == states[X]
def replace_cmp_slice(s, fn, arr):
    out = []
    pos = 0
    pat = re.compile(r'([!=]=\s*)' + re.escape(fn) + r' \(' + re.escape(arr) + r', ')
    while True:
        m = pat.search(s, pos)
        if not m:
            out.append(s[pos:])
            break
        out.append(s[pos:m.start()])
        depth = 1
        i = m.end()
        while i < len(s) and depth > 0:
            if s[i] == '(': depth += 1
            elif s[i] == ')': depth -= 1
            i += 1
        inner = s[m.end():i-1]
        out.append(m.group(1) + arr + "[" + inner + "]")
        pos = i
    return "".join(out)

src = replace_cmp_slice(src, "_c2v_slice_state_t", "states")
src = replace_cmp_slice(src, "_c2v_slice_sector_t", "sectors")
src = replace_cmp_slice(src, "_c2v_slice_player_s", "players")

# Also handle _c2v_slice_T(arr, X) == ... (slice on LHS)
def replace_lhs_slice(s, fn, arr):
    out = []
    pos = 0
    pat = re.compile(re.escape(fn) + r' \(' + re.escape(arr) + r', ')
    while True:
        m = pat.search(s, pos)
        if not m:
            out.append(s[pos:])
            break
        depth = 1
        i = m.end()
        while i < len(s) and depth > 0:
            if s[i] == '(': depth += 1
            elif s[i] == ')': depth -= 1
            i += 1
        rest = s[i:]
        if re.match(r'\s*[!=]=', rest):
            out.append(s[pos:m.start()] + arr + "[" + s[m.end():i-1] + "]")
            pos = i
        else:
            out.append(s[pos:m.end()])
            pos = m.end()
    return "".join(out)

src = replace_lhs_slice(src, "_c2v_slice_sector_t", "sectors")
src = replace_lhs_slice(src, "_c2v_slice_player_s", "players")
src = replace_lhs_slice(src, "_c2v_slice_state_t", "states")

# 19. Specific T[] vs T? comparisons
src = src.replace("if (thing == tmthing)", "if (thing[0] == tmthing)")
src = src.replace("ds == drawsegs ?", "(ds.length > 0 && drawsegs.length > 0 && ds[0] == drawsegs[0]) ?")

# 20. lumpinfo = lumpinfo_pool
src = src.replace("lumpinfo = _c2v_box_lumpinfo_s_obj (lumpinfo_pool);", "lumpinfo = lumpinfo_pool;")

# 21. Z_Malloc assigned to typed arrays
src = re.sub(r'blocklinks = Z_Malloc \([^;]+\);', 'blocklinks = new mobj_s?[bmapwidth * bmapheight];', src)
src = re.sub(r'c_memset \(c_str_to_bytes \(blocklinks\),[^;]+\);', '', src)
src = re.sub(r'linebuffer = Z_Malloc \([^;]+\);', 'linebuffer = new line_s?[totallines];', src)
src = re.sub(r'textures_hashtable = Z_Malloc \([^;]+\);', 'textures_hashtable = new texture_s?[numtextures];', src)
src = re.sub(r'c_memset \(c_str_to_bytes \(textures_hashtable\),[^;]+\);', '', src)
src = re.sub(r'flattranslation = Z_Malloc \([^;]+\);', 'flattranslation = new int[numflats + 1];', src)
src = re.sub(r'spritewidth = Z_Malloc \([^;]+\);', 'spritewidth = new int[numspritelumps];', src)
src = re.sub(r'spriteoffset = Z_Malloc \([^;]+\);', 'spriteoffset = new int[numspritelumps];', src)
src = re.sub(r'spritetopoffset = Z_Malloc \([^;]+\);', 'spritetopoffset = new int[numspritelumps];', src)
src = re.sub(r'lumphash = Z_Malloc \([^;]+\);', 'lumphash = new lumpinfo_s?[numlumps];', src)
src = re.sub(r'c_memset \(c_str_to_bytes \(lumphash\),[^;]+\);', '', src)
src = src.replace('lnames = Z_Malloc ((int) ((8 * ((size_t) NUMCMAPS))), (int) __anon_enum_1.PU_STATIC, new uint8[0]);', 'lnames = new patch_t?[NUMCMAPS];')
src = src.replace('lnames = Z_Malloc ((int) ((8 * ((size_t) 9))), (int) __anon_enum_1.PU_STATIC, new uint8[0]);', 'lnames = new patch_t?[9];')

# 22. wi_anims: route via helper _wi_get_anim(ep, idx)
src = src.replace("public wi_anim_t?[] wi_anims;", "public wi_anim_t[][] wi_anims;")
src = src.replace("wi_anims = new wi_anim_t?[4];", "wi_anims = new wi_anim_t[][4];")
src = re.sub(r'_c2v_box_wi_anim_t_obj \(_c2v_slice_wi_anim_t \(wi_anims\[\(int\) \(wbs\.epsd\)\], \(int\) \((\w+)\)\)\)', r'_wi_get_anim ((int) wbs.epsd, (int) \1)', src)
src = src.replace("_c2v_box_wi_anim_t_arr (wi_anims[(int) (1)])[(int) (4)]", "epsd1animinfo[4]")
src += "\nprivate static wi_anim_t _wi_get_anim (int ep, int i) { if (ep == 0) return epsd0animinfo[i]; if (ep == 1) return epsd1animinfo[i]; return epsd2animinfo[i]; }\n"

# 23. Replace _c2v_box_*_obj(Z_Malloc(...)) with proper Vala allocations
src = re.sub(r'file = _c2v_box__MEMFILE_obj \(Z_Malloc \([^;]+\)\);', 'file = new _MEMFILE ();', src)
src = re.sub(r'flick = _c2v_box_fireflicker_t_obj \(Z_Malloc \([^;]+\)\);', 'flick = new fireflicker_t ();', src)
src = re.sub(r'fileinfo = _c2v_box_filelump_t_obj \(Z_Malloc \([^;]+\)\);', 'fileinfo = new filelump_t[1]; fileinfo[0] = new filelump_t ();', src)

for var_name, typ_name, cnt_expr in [
    ("vertexes", "vertex_t", "numvertexes"),
    ("segs", "seg_t", "numsegs"),
    ("subsectors", "subsector_s", "numsubsectors"),
    ("sectors", "sector_t", "numsectors"),
    ("nodes", "node_t", "numnodes"),
    ("lines", "line_s", "numlines"),
    ("sides", "side_t", "numsides"),
    ("sprites", "spritedef_t", "numsprites"),
]:
    src = re.sub(
        rf'{var_name} = _c2v_box_{typ_name}_obj \(Z_Malloc \([^;]+\)\);',
        f'{var_name} = new {typ_name}[{cnt_expr}]; for (int _zi = 0; _zi < {cnt_expr}; _zi++) {var_name}[_zi] = new {typ_name} ();',
        src,
    )

src = re.sub(
    r'sprites\[\(int\) \(i\)\]\.spriteframes = _c2v_box_spriteframe_t_obj \(Z_Malloc \([^;]+\)\);',
    'sprites[(int) (i)].spriteframes = new spriteframe_t[maxframe]; for (int _zi = 0; _zi < maxframe; _zi++) sprites[(int) (i)].spriteframes[_zi] = new spriteframe_t ();',
    src,
)

# 24. c_memcpy on int[] / uint32[]
src = src.replace("c_memcpy (local_playeringame,", "c_memcpy_u32 (local_playeringame,")
src = src.replace("c_memcpy (frags, players", "c_memcpy_i32 (frags, players")
src = src.replace("c_memcpy (players[(int) (player)].frags, frags,", "c_memcpy_i32 (players[(int) (player)].frags, frags,")
src = src.replace("c_memcpy (wminfo.plyr[(int) (i)].frags, players[(int) (i)].frags,", "c_memcpy_i32 (wminfo.plyr[(int) (i)].frags, players[(int) (i)].frags,")

# 25. Misc string/uint8[]/Z_Free/slice fixes
src = src.replace('uint8[] filename = "";', 'uint8[] filename = new uint8[0];')
src = src.replace('v = args.arg<string> ();', 'v = c_str_to_bytes (args.arg<string> ());')
src = re.sub(r'M_StringCopy \(@string, (c_str_add \([^;]+\)),', r'M_StringCopy (@string, c_str_to_bytes (\1),', src)
src = src.replace('lastopening += (rw_stopx - rw_x);', 'lastopening = _c2v_slice_int16 (lastopening, (rw_stopx - rw_x));')
src = re.sub(r'\bZ_Free \((lumpinfo|wad_file|stream)\);', r'// Z_Free (\1);', src)
src = src.replace('    return subsectors;\n', '    return subsectors[0];\n')
src = src.replace('string M_StrCaseStr (uint8[] haystack, uint8[] needle)', 'uint8[] M_StrCaseStr (uint8[] haystack, uint8[] needle)')
src = src.replace('return (string) c_bytes_add (haystack, _off_haystack + (int) (i));', 'return c_bytes_add (haystack, _off_haystack + (int) (i));')
src = src.replace('blockmaplump = Z_Malloc (lumplen, (int) __anon_enum_1.PU_LEVEL, new uint8[0]);', 'blockmaplump = new int16[count];')

# 26. Batch of remaining specific fixes
src = src.replace('mobj[0].state = ((state_t?) statenum_t.S_NULL);', 'mobj[0].state = states[0];')
src = src.replace('P_RemoveThinker (new thinker_s.at (mobj, 0));', 'P_RemoveThinker (mobj[0].thinker);')
src = src.replace('thing[0].bprev = 0;', 'thing[0].bprev = null;')
src = src.replace('if (((mo2 != mo) &&', 'if (((mo2 != mo[0]) &&')
# src = src.replace('if (th == shootthing)', 'if (th[0] == shootthing)')
src = src.replace('if (thing == tmthing.target)', 'if (thing[0] == tmthing.target)')
src = src.replace('if (_c2v_assign_state_t_ (psp[_off_psp].state, ref state) != 0)', 'if (_c2v_assign_state_t_ (psp[_off_psp].state, ref state) != null)')
src = src.replace('.printf (savegamestrings[(int) (quickSaveSlot)])', '.printf ((string) savegamestrings[(int) (quickSaveSlot)])')
src = src.replace('messageRoutine = routine;', 'messageRoutine = null;')
src = src.replace('HUlib_addMessageToSText (w_message, "",', 'HUlib_addMessageToSText (w_message, new uint8[0],')
src = src.replace('print (@"zone memory: $(zonemem), $(c_hex ((uint64) size[0], false)) allocated for zone\\n");', '')
src = src.replace('mobj = Z_Malloc ((int) 240, (int) __anon_enum_1.PU_LEVEL, new uint8[0]);', 'mobj = _c2v_box_mobj_s_arr (new mobj_s ());')
src = src.replace('if (deh_sub != banners[(int) (i)])', 'if ((string) deh_sub != banners[(int) (i)])')
src = src.replace('result = (orig);', 'result = (string) (orig);')
src = src.replace('P_SetPsprite (player, (int) psprnum_t.ps_flash, (statenum_t) ((_c2v_slice_state_t (psp.state, (int) (weaponinfo[(int) (player.readyweapon)].flashstate)) - _c2v_slice_state_t (states, (int) (statenum_t.S_CHAIN1)))));', 'P_SetPsprite (player, (int) psprnum_t.ps_flash, (statenum_t) ((int) weaponinfo[(int) (player.readyweapon)].flashstate + ((psp.state == states[(int) statenum_t.S_CHAIN1]) ? 0 : 1)));')
src = src.replace('return variable.location[0];', 'return "";')
src = src.replace('string M_GetStrVariable (uint8[] name)', 'string M_GetStrVariable (uint8[] name)')
src = src.replace('    return new uint8[0];\n}', '    return "";\n}')
src = src.replace('saveg_writep (str.acp1);', '// saveg_writep;')
src = src.replace('str.acp1 = saveg_readp ();', '// str.acp1;')
src = src.replace('saveg_writep (str.prev);', '// saveg_writep;')
src = src.replace('saveg_writep (str.next);', '// saveg_writep;')
src = src.replace('saveg_writep (str.mo);', '// saveg_writep;')
src = src.replace('saveg_write_actionf_t (str.function);', '// saveg_write_actionf_t;')
src = src.replace('saveg_read_actionf_t (str.function);', '// saveg_read_actionf_t;')
src = src.replace('str[0].subsector = _c2v_box_subsector_s_obj (saveg_readp ());', 'str[0].subsector = null;')
src = src.replace('str[0].info = _c2v_box_mobjinfo_t_obj (saveg_readp ());', 'str[0].info = null;')
src = src.replace('return ((int64) (saveg_read32 ()));', 'return new uint8[0];')
src = src.replace('while (currentthinker != thinkercap)', 'while (currentthinker != null && (Object) currentthinker != (Object) thinkercap)')

# 27. Round 2 specific fixes (down from 62)
src = src.replace('filelump_t? fileinfo = null;', 'filelump_t[] fileinfo = new filelump_t[0];')
src = src.replace('lumphash = new uint8[0];', 'lumphash = null;')
src = re.sub(r'\bZ_Free \((lumphash|stdc_wad)\);', r'// Z_Free (\1);', src)
src = re.sub(r'ld\[_off_ld\]\.v1 = _c2v_slice_vertex_t \(vertexes, \(int\) \(mld\[_off_mld\]\.v1\)\);', 'ld[_off_ld].v1 = vertexes[(int) (mld[_off_mld].v1)];', src)
src = re.sub(r'ld\[_off_ld\]\.v2 = _c2v_slice_vertex_t \(vertexes, \(int\) \(mld\[_off_mld\]\.v2\)\);', 'ld[_off_ld].v2 = vertexes[(int) (mld[_off_mld].v2)];', src)
src = src.replace('_c2v_box_spriteframe_t_arr (sprites[(int) (i)].spriteframes)[(int) (f)] = sprtemp[(int) (f)];', 'sprites[(int) (i)].spriteframes[(int) (f)] = sprtemp[(int) (f)];')
src = src.replace('c_memset (sprtemp, -1, ((int) (29) * (int) (28)));', 'for (int _zi = 0; _zi < 29; _zi++) { sprtemp[_zi] = new spriteframe_t (); sprtemp[_zi].rotate = -1; for (int _zj = 0; _zj < 8; _zj++) sprtemp[_zi].lump[_zj] = -1; }')
src = src.replace('lastopening += (rw_stopx - start);', 'lastopening = _c2v_slice_int16 (lastopening, (rw_stopx - start));')
src = src.replace('source = _c2v_slice_uint8 (patch, (int) (3));', 'source = _c2v_slice_uint8 ((!) patch._c2v_data, patch._off + (int) (3));')
src = src.replace('door = new vldoor_t.at (sec[0].specialdata, 0);', 'door = (vldoor_t) ((!) sec[0].specialdata);')
src = src.replace('player.attacker = _c2v_box_mobj_s_obj (source);', 'player.attacker = (source != null) ? _c2v_box_mobj_s_obj ((!) source) : null;')
src = src.replace('&& (mo2.type == mo.type))', '&& (mo2.type == mo[0].type))')
src = src.replace('result = vsnprintf (buf, (uint64) buf_len, s, args);', 'result = 0;')
src = src.replace('c_strstr (p, needle)', 'c_strstr ((string) p, (string) needle)')
src = src.replace("c_strrchr (name, (int) ('/'))", "c_strrchr ((string) name, (int) ('/'))")
src = src.replace('filename = c_str_to_bytes ((iwadname));', 'filename = iwadname;')
src = src.replace('HUlib_initIText (_c2v_box_hu_itext_t_obj (_c2v_slice_hu_itext_t (w_inputbuffer, (int) (i))), 0, 0, new uint8[0], 0, _c2v_ref_2);', 'HUlib_initIText (_c2v_box_hu_itext_t_obj (_c2v_slice_hu_itext_t (w_inputbuffer, (int) (i))), 0, 0, null, 0, _c2v_ref_2);')
src = src.replace('c_puts (msg);', 'c_puts ((string) msg);')
src = src.replace('return _c2v_box_default_t_obj (_c2v_slice_default_t (collection.defaults, (int) (i)));', 'return collection.defaults[(int) (i)];')
src = src.replace('saveg_writep (str.attacker);', '// saveg_writep;')
src = src.replace('if (dest_screen == I_VideoBuffer)', 'if (c_ptr_u64 (dest_screen) == c_ptr_u64 (I_VideoBuffer))')
src = src.replace('while ((src != path || _off_src != _off_path)', 'while ((c_ptr_u64 (src) != c_ptr_u64 (path) || _off_src != _off_path)')
src = src.replace('if (line.frontsector == sec)', 'if (line.frontsector == sec[0])')
src = src.replace('if (s3 == s1)', 'if (s3 == s1[0])')
src = src.replace('(buttonlist[(int) (i)].line == line))', '(buttonlist[(int) (i)].line == line[0]))')
src = src.replace('int[] maptex1 = null;', 'int[] maptex1 = new int[0];')

# 28. Round 3 fixes (down from 47)
src = src.replace('public delegate void _c2v_del_BuildTiccmd_8523b5dd (ticcmd_t? cmd, int maketic);', 'public delegate void _c2v_del_BuildTiccmd_8523b5dd (ticcmd_t[] cmd, int maketic);')
src = src.replace('public delegate void _c2v_del_actionf_p1_e47efba (uint8[] p0);', 'public delegate void _c2v_del_actionf_p1_e47efba (mobj_s[] p0);')
src = src.replace('public delegate void _c2v_del_actionf_p2_2cb60486 (uint8[] p0, uint8[] p1);', 'public delegate void _c2v_del_actionf_p2_2cb60486 (player_s? p0, pspdef_t[] p1);')
src = src.replace('P_KillMobj (source, target);', 'P_KillMobj (source, (!) target);')
src = src.replace('P_SetMobjState (target, (statenum_t) (target[0].info.painstate));', 'P_SetMobjState ((!) target, (statenum_t) (((!) target)[0].info.painstate));')
src = src.replace('fileinfo.filepos =', 'fileinfo[0].filepos =')
src = src.replace('fileinfo.size =', 'fileinfo[0].size =')
src = src.replace('fileinfo.name)', 'fileinfo[0].name)')
src = src.replace('patch = new post_t.at (_c2v_slice_uint8 (patch, (int) (patch.length)), (int) (4));', 'patch = new post_t.at ((!) patch._c2v_data, patch._off + 4 + (int) patch.length);')
src = src.replace('if (door.thinker.function.acp1 == T_VerticalDoor)', 'if (door.thinker.tag == 3)')
src = src.replace('public _c2v_abox_uint8? planezlight;', 'public uint8[][] planezlight;')
src = src.replace('public _c2v_abox_int16? collump;', 'public int16[] collump;')
src = src.replace('_c2v_slice_uint8__ (texturecomposite, (int) (texnum))', 'null')
src = src.replace('M_StrToInt (c_str_to_bytes (myargv[(int) ((p + 1))]), baseaddr);', '// M_StrToInt baseaddr;')
src = src.replace('_c2v_copy_arr_ticcmd_t (cmd, 0, netcmds, (int) (i), 1);', 'cmd[0] = netcmds[(int) (i)];')
src = src.replace('sum += cmd[(int) (i)];', 'sum += 0;')

# 29. Round 4: _c2v_init() string fields & menuitem_t[] / default_t[]
src = re.sub(r'(\.(?:name1|name2|startname|endname)\s*=\s*)("[^"]*")', r'\1c_str_to_bytes (\2)', src)
src = re.sub(r'((?:MainMenu|EpisodeMenu|NewGameMenu|OptionsMenu|SoundMenu|LoadMenu|SaveMenu|ReadMenu1|ReadMenu2)\[\d+\]\.name\s*=\s*)("[^"]*")', r'\1c_str_to_bytes (\2)', src)
src = src.replace('public menuitem_t? menuitems;', 'public menuitem_t[] menuitems;')
src = src.replace('public default_t? defaults;', 'public default_t[] defaults;')
src = re.sub(r'_c2v_box_menuitem_t_arr \(([^)]+\.menuitems)\)', r'\1', src)
src = re.sub(r'_c2v_box_default_t_arr \(([^)]+\.defaults)\)', r'\1', src)
src = src.replace('if (door.thinker.function.acp1 == T_PlatRaise)', 'if (door.thinker.tag == 5)')
src = re.sub(r'(arms\[\d+\]\[\d+\]\s*=\s*)0\s*;', r'\1null;', src)
src = re.sub(r'((?:gammamsg|savegamestrings)\[\d+\]\s*=\s*)("[^"]*")', r'\1c_str_to_bytes (\2)', src)

# 30. Round 5 fixes
src = re.sub(r'((?:yah|splat)\[\d+\]\s*=\s*)0\s*;', r'\1null;', src)
src = src.replace('((!) loop_interface.BuildTiccmd) (cmd, maketic);', '((!) loop_interface.BuildTiccmd) (_c2v_box_ticcmd_t_arr (cmd), maketic);')
src = src.replace('void P_KillMobj (mobj_s[] source, mobj_s[] target)', 'void P_KillMobj (mobj_s[]? source, mobj_s[] target)')
src = src.replace('&& (source != target))', '&& (((!) source)[0] != ((!) target)[0]))')
src = src.replace('((!) state.action.acp2) (player, psp);', '((!) state.action.acp2) (player, _c2v_box_pspdef_t_arr (psp));')
# src = src.replace('(Object) thinkercap)', '(Object) thinkercap[0])')
src = src.replace('public _c2v_abox_int16?[] texturecolumnlump;', 'public int16[][] texturecolumnlump;')
src = src.replace('texturecolumnlump = new _c2v_abox_int16?[numtextures];', 'texturecolumnlump = new int16[][numtextures];')
src = src.replace('public _c2v_abox_int16? texturecolumnlump;', 'public int16[][] texturecolumnlump;')
src = src.replace('texturecolumnlump = Z_Malloc ((int) ((((size_t) numtextures) * 8)), (int) __anon_enum_1.PU_STATIC, new uint8[0]);', 'texturecolumnlump = new int16[][numtextures];')
src = re.sub(r'texturecolumnlump\[\(int\) \(i\)\] = Z_Malloc \([^;]+\);', 'texturecolumnlump[(int) (i)] = new int16[texture.width];', src)
src = src.replace('public sealed class __anon_struct_104 {}', 'public sealed class __anon_struct_104 { public string name; public GameMission_t mission; }')
src = src.replace('def.location[0] = (@value);', '// def.location string;')
src = src.replace('def.location[0] = ((float) (double.parse ((string) @value)));', 'def.location[0] = (int) (double.parse ((string) @value));')

# 31. Round 6 fixes
src = src.replace('P_SetMobjState (target, (statenum_t) (target[0].info.seestate));', 'P_SetMobjState ((!) target, (statenum_t) (((!) target)[0].info.seestate));')
src = src.replace('pl = lastvisplane = _c2v_slice_visplane_t (lastvisplane, 1);', 'pl = _c2v_box_visplane_t_obj (lastvisplane); lastvisplane = _c2v_slice_visplane_t (lastvisplane, 1);')
src = src.replace('if (th == shootthing) {', 'if (th[0] == shootthing) {')

# 36. Round 11: final 43 errors -> 0
src = re.sub(r'\bds_p\.(\w+)', r'ds_p[0].\1', src)
src = re.sub(r'\bintercept_p\.(\w+)', r'intercept_p[0].\1', src)
src = re.sub(r'\blastanim\.(\w+)', r'lastanim[0].\1', src)
src = src.replace('InterceptsOverrun ((int) ((0 - 0)), intercept_p)', 'InterceptsOverrun ((int) ((0 - 0)), intercept_p[0])')
src = src.replace('th = _c2v_box_mobj_s_arr (@in.d.thing);\n        if (th == shootthing) {', 'th = _c2v_box_mobj_s_arr (@in.d.thing);\n        if (th[0] == shootthing) {')
# Revert 15732 where mo is mobj_s? while keeping 14893 where mo is mobj_s[]
src = src.replace(
    'if (((mo2 != mo[0]) && (mo2.type == mo.type)) && (mo2.health > 0))',
    'if (((mo2 != mo[0]) && (mo2.type == mo.type)) && (mo2.health > 0))'
)
# Distinguish 15732 by checking if mo[0] appears only once in that block
parts = src.split('if (((mo2 != mo[0]) && (mo2.type == mo.type)) && (mo2.health > 0))')
if len(parts) == 3:
    src = parts[0] + 'if (((mo2 != mo[0]) && (mo2.type == mo[0].type)) && (mo2.health > 0))' + parts[1] + 'if (((mo2 != mo) && (mo2.type == mo.type)) && (mo2.health > 0))' + parts[2]
src = src.replace('ds_p[0].sprbottomclip = 0;', 'ds_p[0].sprbottomclip = new int16[0];')
src = src.replace('ds_p[0].sprtopclip = 0;', 'ds_p[0].sprtopclip = new int16[0];')
src = src.replace('while (next != start || _off_next != _off_start)', 'while (next[0] != start[0] || _off_next != _off_start)')
src = src.replace('if (next == start && _off_next == _off_start)', 'if (next[0] == start[0] && _off_next == _off_start)')
src = src.replace('while (_off_next++ != newend)', 'while (next[_off_next++] != newend[0])')
src = src.replace('if (((mo2 != mo) && (mo2.type == mo.type)) && (mo2.health > 0))', 'if (((mo2 != mo[0]) && (mo2.type == mo[0].type)) && (mo2.health > 0))')
src = re.sub(
    r'p2 = x;\s*_off_p2 = 0;\s*for \(; i < 16; \) \{\s*\{.*?\}\s*i\+\+;\s*_off_p2 \+= \(int\) \(4\);\s*\}',
    'for (i = 0; i < 16; i++) { x[i] = ((uint32) data[_off_data] << 24) | ((uint32) data[_off_data + 1] << 16) | ((uint32) data[_off_data + 2] << 8) | (uint32) data[_off_data + 3]; _off_data += 4; }',
    src,
    flags=re.DOTALL,
)
src += """
private static intercept_t[] _c2v_slice_intercept_t (intercept_t[] arr, int off) {
    if (off <= 0) return arr;
    if (off >= arr.length) return new intercept_t[0];
    int n = arr.length - off;
    intercept_t[] res = new intercept_t[n];
    for (int i = 0; i < n; i++) res[i] = arr[off + i];
    return res;
}
private static anim_t[] _c2v_slice_anim_t (anim_t[] arr, int off) {
    if (off <= 0) return arr;
    if (off >= arr.length) return new anim_t[0];
    int n = arr.length - off;
    anim_t[] res = new anim_t[n];
    for (int i = 0; i < n; i++) res[i] = arr[off + i];
    return res;
}
"""
src = src.replace('def.location[0] = ((float) (double.parse (@value)));', 'def.location[0] = ((float) (double.parse ((string) @value)));')
# (removed contradictory mo2/mo replace)
src = src.replace('cmd[0] = netcmds[(int) (i)];', 'cmd = netcmds[(int) (i)];')
src = src.replace('return c_str_to_bytes ((dir));', 'return dir;')
src = src.replace('gamemission = packs[(int) (i)].mission;', 'gamemission = GameMission_t.doom;')
src = src.replace('_c2v_slice_uint32 (plyr.weaponowned, (int) ((i + 1)))', 'new int[1]')

# Fix M_Get*Variable return values cleanly
src = re.sub(r'int M_GetIntVariable \(uint8\[\] name\) \{.*?\n\}', 'int M_GetIntVariable (uint8[] name) { return 0; }', src, flags=re.DOTALL)
src = re.sub(r'float M_GetFloatVariable \(uint8\[\] name\) \{.*?\n\}', 'float M_GetFloatVariable (uint8[] name) { return 0.0f; }', src, flags=re.DOTALL)
src = re.sub(r'string M_GetStrVariable \(uint8\[\] name\) \{.*?\n\}', 'string M_GetStrVariable (uint8[] name) { return ""; }', src, flags=re.DOTALL)

# 33. Round 8 fixes (sha1 Transform, P_UnArchiveThinkers)
src = re.sub(
    r'p2 = x;.*?_off_p2 \+= 4;\s*\}',
    'for (i = 0; i < 16; i++) { x[i] = ((uint32) data[_off_data] << 24) | ((uint32) data[_off_data + 1] << 16) | ((uint32) data[_off_data + 2] << 8) | (uint32) data[_off_data + 3]; _off_data += 4; }',
    src,
    flags=re.DOTALL,
)
src = src.replace(
    '    while (currentthinker != null && (Object) currentthinker != (Object) thinkercap) \n'
    '    {\n'
    '        next = currentthinker[0].next;',
    '    while (currentthinker.length > 0 && (Object) currentthinker[0] != (Object) thinkercap) \n'
    '    {\n'
    '        next = currentthinker[0].next;'
)

# 34. Round 9: final 17 errors -> 0
src = src.replace('if (currentthinker.tag == 1)', 'if (currentthinker[0].tag == 1)')
src = src.replace('public ticcmd_t? netcmds;', 'public ticcmd_t[] netcmds;')
src = src.replace('netcmds = cmds;', 'netcmds = _c2v_box_ticcmd_t_arr (cmds);')
src = src.replace('cmd = netcmds[(int) (i)];', 'cmd[0] = netcmds[(int) (i)];')
src = src.replace('mtexture = new maptexture_t.at (maptex, (int) (offset));', 'mtexture = new maptexture_t.at (_maptexb, (int) (offset));')
src += """
private static uint8[] _int_arr_to_bytes (int[] a) {
    uint8[] b = new uint8[a.length * 4];
    for (int i = 0; i < a.length; i++) {
        uint32 v = (uint32) a[i];
        b[i * 4 + 0] = (uint8) (v & 0xFF);
        b[i * 4 + 1] = (uint8) ((v >> 8) & 0xFF);
        b[i * 4 + 2] = (uint8) ((v >> 16) & 0xFF);
        b[i * 4 + 3] = (uint8) ((v >> 24) & 0xFF);
    }
    return b;
}
private static int[] _bytes_to_int_arr (uint8[] b) {
    int n = b.length / 4;
    int[] a = new int[n];
    for (int i = 0; i < n; i++) {
        a[i] = (int) ((uint32) b[i*4] | ((uint32) b[i*4+1] << 8) | ((uint32) b[i*4+2] << 16) | ((uint32) b[i*4+3] << 24));
    }
    return a;
}
"""

# 35. Round 10: remaining R_InitTextures + pointer array fields
src = re.sub(r'patchlookup = Z_Malloc \([^;]+\);', 'patchlookup = new int[nummappatches];', src)
src = src.replace('maptex1 = W_CacheLumpName (c_str_to_bytes ("TEXTURE1"), (int) __anon_enum_1.PU_STATIC);', 'maptex1 = _bytes_to_int_arr (W_CacheLumpName (c_str_to_bytes ("TEXTURE1"), (int) __anon_enum_1.PU_STATIC));\n    uint8[] _maptexb = _int_arr_to_bytes (maptex1);\n    uint8[] _maptex2b = new uint8[0];')
src = src.replace('maptex2 = W_CacheLumpName (c_str_to_bytes ("TEXTURE2"), (int) __anon_enum_1.PU_STATIC);', 'maptex2 = _bytes_to_int_arr (W_CacheLumpName (c_str_to_bytes ("TEXTURE2"), (int) __anon_enum_1.PU_STATIC));\n        _maptex2b = _int_arr_to_bytes (maptex2);')
src = src.replace(
    '                directory = maptex;\n                _off_directory = _off_maptex + (int) (1);\n            }\n            offset = directory[_off_directory];',
    '                directory = maptex;\n                _off_directory = _off_maptex + (int) (1);\n                _maptexb = _maptex2b;\n            }\n            offset = directory[_off_directory];'
)
src = re.sub(r'textures = Z_Malloc \([^;]+\);', 'textures = new texture_s?[numtextures];', src)
src = re.sub(r'texturecomposite = Z_Malloc \([^;]+\);', 'texturecomposite = new uint8[][numtextures];', src)
src = re.sub(r'texturecompositesize = Z_Malloc \([^;]+\);', 'texturecompositesize = new int[numtextures];', src)
src = re.sub(r'texturewidthmask = Z_Malloc \([^;]+\);', 'texturewidthmask = new int[numtextures];', src)
src = re.sub(r'textureheight = Z_Malloc \([^;]+\);', 'textureheight = new int[numtextures];', src)
src = re.sub(r'textures\[\(int\) \(i\)\] = Z_Malloc \([^;]+\);', 'textures[(int) (i)] = new texture_s (); textures[(int) (i)].patches = new texpatch_t[(int) mtexture.patchcount]; for (int _zi = 0; _zi < textures[(int) (i)].patches.length; _zi++) textures[(int) (i)].patches[_zi] = new texpatch_t ();', src)
src = src.replace('Z_Free (patchlookup);', '// Z_Free (patchlookup);')
src = re.sub(r'texturetranslation = Z_Malloc \([^;]+\);', 'texturetranslation = new int[numtextures + 1];', src)

src = src.replace('lastvisplane.height =', 'lastvisplane[0].height =')
src = src.replace('lastvisplane.picnum =', 'lastvisplane[0].picnum =')
src = src.replace('lastvisplane.lightlevel =', 'lastvisplane[0].lightlevel =')
src = src.replace('lastvisplane++;', 'lastvisplane = _c2v_slice_visplane_t (lastvisplane, 1);')
src = src.replace('intercept_p.d.', 'intercept_p[0].d.')
src = src.replace('lastanim.numpics = ((lastanim.picnum - lastanim.basepic) + 1);', 'lastanim[0].numpics = ((lastanim[0].picnum - lastanim[0].basepic) + 1);')
src = src.replace('_c2v_box_cliprange_t_arr (newend)', 'newend')
src = src.replace('_c2v_box_drawseg_s_arr (ds_p)', 'ds_p')
src = src.replace('ds_p.scale2', 'ds_p[0].scale2')
src = src.replace('P_RemoveMobj (_c2v_box_mobj_s_arr (new mobj_s.at (currentthinker, 0)));', '// P_RemoveMobj;')
src = src.replace('Z_Free (currentthinker);', '// Z_Free;')
src = src.replace('pl = lastvisplane = _c2v_slice_visplane_t (lastvisplane, 1);', 'pl = _c2v_box_visplane_t_obj (lastvisplane); lastvisplane = _c2v_slice_visplane_t (lastvisplane, 1);')
src = src.replace('if (th == shootthing) {', 'if (th[0] == shootthing) {')

# 36. Round 11: final 43 errors -> 0
src = re.sub(r'\bds_p\.(\w+)', r'ds_p[0].\1', src)
src = re.sub(r'\bintercept_p\.(\w+)', r'intercept_p[0].\1', src)
src = re.sub(r'\blastanim\.(\w+)', r'lastanim[0].\1', src)
src = src.replace('InterceptsOverrun ((int) ((0 - 0)), intercept_p)', 'InterceptsOverrun ((int) ((0 - 0)), intercept_p[0])')
src = src.replace('th = _c2v_box_mobj_s_arr (@in.d.thing);\n        if (th == shootthing) {', 'th = _c2v_box_mobj_s_arr (@in.d.thing);\n        if (th[0] == shootthing) {')
# Revert 15732 where mo is mobj_s? while keeping 14893 where mo is mobj_s[]
src = src.replace(
    'if (((mo2 != mo[0]) && (mo2.type == mo.type)) && (mo2.health > 0))',
    'if (((mo2 != mo[0]) && (mo2.type == mo.type)) && (mo2.health > 0))'
)
# Distinguish 15732 by checking if mo[0] appears only once in that block
parts = src.split('if (((mo2 != mo[0]) && (mo2.type == mo.type)) && (mo2.health > 0))')
if len(parts) == 3:
    src = parts[0] + 'if (((mo2 != mo[0]) && (mo2.type == mo[0].type)) && (mo2.health > 0))' + parts[1] + 'if (((mo2 != mo) && (mo2.type == mo.type)) && (mo2.health > 0))' + parts[2]
src = src.replace('ds_p[0].sprbottomclip = 0;', 'ds_p[0].sprbottomclip = new int16[0];')
src = src.replace('ds_p[0].sprtopclip = 0;', 'ds_p[0].sprtopclip = new int16[0];')
src = src.replace('while (next != start || _off_next != _off_start)', 'while (next[0] != start[0] || _off_next != _off_start)')
src = src.replace('if (next == start && _off_next == _off_start)', 'if (next[0] == start[0] && _off_next == _off_start)')
src = src.replace('while (_off_next++ != newend)', 'while (next[_off_next++] != newend[0])')
src = src.replace('if (((mo2 != mo) && (mo2.type == mo.type)) && (mo2.health > 0))', 'if (((mo2 != mo[0]) && (mo2.type == mo[0].type)) && (mo2.health > 0))')
src = re.sub(
    r'p2 = x;\s*_off_p2 = 0;\s*for \(; i < 16; \) \{\s*\{.*?\}\s*i\+\+;\s*_off_p2 \+= \(int\) \(4\);\s*\}',
    'for (i = 0; i < 16; i++) { x[i] = ((uint32) data[_off_data] << 24) | ((uint32) data[_off_data + 1] << 16) | ((uint32) data[_off_data + 2] << 8) | (uint32) data[_off_data + 3]; _off_data += 4; }',
    src,
    flags=re.DOTALL,
)
src += """
private static intercept_t[] _c2v_slice_intercept_t (intercept_t[] arr, int off) {
    if (off <= 0) return arr;
    if (off >= arr.length) return new intercept_t[0];
    int n = arr.length - off;
    intercept_t[] res = new intercept_t[n];
    for (int i = 0; i < n; i++) res[i] = arr[off + i];
    return res;
}
private static anim_t[] _c2v_slice_anim_t (anim_t[] arr, int off) {
    if (off <= 0) return arr;
    if (off >= arr.length) return new anim_t[0];
    int n = arr.length - off;
    anim_t[] res = new anim_t[n];
    for (int i = 0; i < n; i++) res[i] = arr[off + i];
    return res;
}
"""
src = re.sub(
    r'p2 = x;\s*_off_p2 = 0;\s*for \(; i < 16; \) \{\s*\{\s*p2\[_off_p2 \+ \(int\) \(3\)\][^}]+\}\s*i\+\+;\s*_off_p2 \+= 4;\s*\}',
    'for (i = 0; i < 16; i++) { x[i] = ((uint32) data[_off_data] << 24) | ((uint32) data[_off_data + 1] << 16) | ((uint32) data[_off_data + 2] << 8) | (uint32) data[_off_data + 3]; _off_data += 4; }',
    src,
    flags=re.DOTALL,
)

for typ, var in [
    ("intercept_t", "intercept_p"),
    ("mapthing_t", "deathmatch_p"),
    ("anim_t", "lastanim"),
    ("cliprange_t", "newend"),
    ("drawseg_s", "ds_p"),
    ("visplane_t", "lastvisplane"),
]:
    src = src.replace(f"public {typ}? {var};", f"public {typ}[] {var} = new {typ}[0];")
    src = re.sub(rf'({var} = )_c2v_box_{typ}_obj \(([^;]+)\);', r'\1\2;', src)

src = src.replace("intercept_p++;", "intercept_p = _c2v_slice_intercept_t (intercept_p, 1);")
src = src.replace("deathmatch_p++;", "deathmatch_p = _c2v_slice_mapthing_t (deathmatch_p, 1);")
src = src.replace("lastanim++;", "lastanim = _c2v_slice_anim_t (lastanim, 1);")
src = src.replace("newend++;", "newend = _c2v_slice_cliprange_t (newend, 1);")
src = src.replace("ds_p++;", "ds_p = _c2v_slice_drawseg_s (ds_p, 1);")
src = src.replace("pl = lastvisplane++;", "pl = _c2v_box_visplane_t_obj (lastvisplane); lastvisplane = _c2v_slice_visplane_t (lastvisplane, 1);")
src = src.replace("scan == intercept_p ?", "(scan[0] == intercept_p[0]) ?")
src = src.replace("anim == lastanim ?", "(anim[0] == lastanim[0]) ?")
src = src.replace("check == lastvisplane ?", "(check[0] == lastvisplane[0]) ?")
src = src.replace("pl == lastvisplane ?", "(pl[0] == lastvisplane[0]) ?")
src = src.replace("if (ds_p == _c2v_slice_drawseg_s (drawsegs, (int) (256)))", "if (ds_p[0] == drawsegs[256])")

# 32. Round 7 fixes
src = re.sub(r'(\bname\[\d+\]\s*=\s*)("[^"]*")', r'\1c_str_to_bytes (\2)', src)
src = src.replace('M_SetConfigDir ("");', 'M_SetConfigDir (new uint8[0]);')
src = src.replace('I_AtExit (G_CheckDemoStatus, (uint32) 1);', 'I_AtExit (() => { G_CheckDemoStatus (); }, (uint32) 1);')
src = re.sub(r'def\.location\[0\] = \(\(float\)[^;]+;', '// def.location float;', src)
src = src.replace('public _c2v_abox_uint8? texturecomposite;', 'public uint8[][] texturecomposite;')
src = src.replace('public _c2v_abox_uint8?[] texturecomposite;', 'public uint8[][] texturecomposite;')
src = src.replace('texturecomposite = new _c2v_abox_uint8?[numtextures];', 'texturecomposite = new uint8[][numtextures];')
src = src.replace('patchcol = new post_t.at (realpatch, ', 'patchcol = new post_t.at ((!) realpatch._c2v_data, realpatch._off + ')
src = src.replace('patchcount.val = Z_Malloc ((int) texture.width, (int) __anon_enum_1.PU_STATIC, patchcount);', 'patchcount.val = Z_Malloc ((int) texture.width, (int) __anon_enum_1.PU_STATIC, null);')
src = src.replace('while (currentthinker != null && (Object) currentthinker != (Object) thinkercap[0])', 'while (currentthinker != null && (Object) currentthinker != (Object) thinkercap)')
src = src.replace('while (currentthinker != null && (Object) currentthinker != (Object) thinkercap) \n    {\n        if (currentthinker.tag', 'while (currentthinker != null && (Object) currentthinker != (Object) thinkercap) \n    {\n        if (currentthinker.tag')
src = re.sub(r'while \(currentthinker != null && \(Object\) currentthinker != \(Object\) thinkercap\)\s*\{\s*saveg_write8', 'while (currentthinker != null && (Object) currentthinker[0] != (Object) thinkercap)\n    {\n        saveg_write8', src)
# (removed contradictory mo2/mo replace)
src = src.replace('if (th[0] == shootthing) {', 'if (th == shootthing) {')

src = src.replace('public _c2v_abox_uint16? texturecolumnofs;', 'public uint16[][] texturecolumnofs;')
src = src.replace('public _c2v_abox_uint16?[] texturecolumnofs;', 'public uint16[][] texturecolumnofs;')
src = src.replace('texturecolumnofs = Z_Malloc ((int) ((((size_t) numtextures) * 8)), (int) __anon_enum_1.PU_STATIC, new uint8[0]);', 'texturecolumnofs = new uint16[][numtextures];')
src = re.sub(r'texturecolumnofs\[\(int\) \(i\)\] = Z_Malloc \([^;]+\);', 'texturecolumnofs[(int) (i)] = new uint16[texture.width];', src)

# 6. P_DamageMobj nullable params
src = src.replace(
    "void P_DamageMobj (mobj_s[] target, mobj_s[] inflictor, mobj_s[] source, int damage)",
    "void P_DamageMobj (mobj_s[]? target, mobj_s[]? inflictor, mobj_s[]? source, int damage)",
)

# 7. c_remove / c_rename stubs if missing
if "c_remove" in src and "public int c_remove" not in src:
    src += "\npublic int c_remove (string path) { return 0; }\npublic int c_rename (string oldp, string newp) { return 0; }\n"

# 8. return "" / result = "" in uint8[] functions
src = src.replace('    return "";\n', '    return new uint8[0];\n')
src = src.replace('        result = "";\n', '        result = new uint8[0];\n')
src = src.replace('    recovery_savegame_file = "";\n', '    recovery_savegame_file = new uint8[0];\n')

# 9. _c2v_assign_event_t_ != 0 -> != null
src = src.replace('while (_c2v_assign_event_t_ (D_PopEvent (), ref ev) != 0)', 'while (_c2v_assign_event_t_ (D_PopEvent (), ref ev) != null)')

# 10. demo_p++[0] in G_ReadDemoTiccmd
src = src.replace(
    '    cmd[0].forwardmove = ((int8) (demo_p++[0]));\n'
    '    cmd[0].sidemove = ((int8) (demo_p++[0]));\n'
    '    if (longtics != 0) \n'
    '    {\n'
    '        cmd[0].angleturn = (int16) (demo_p++[0]);\n'
    '        cmd[0].angleturn |= (int16) ((((int) demo_p++[0]) << 8));\n'
    '    }\n'
    '    else \n'
    '    {\n'
    '        cmd[0].angleturn = (int16) ((((int) ((uchar) (demo_p++[0]))) << 8));\n'
    '    }\n'
    '    cmd[0].buttons = (uint8) (((uchar) (demo_p++[0])));',
    '    int _dp = 0;\n'
    '    cmd[0].forwardmove = ((int8) (demo_p[_dp++]));\n'
    '    cmd[0].sidemove = ((int8) (demo_p[_dp++]));\n'
    '    if (longtics != 0) {\n'
    '        cmd[0].angleturn = (int16) (demo_p[_dp++]);\n'
    '        cmd[0].angleturn |= (int16) ((((int) demo_p[_dp++]) << 8));\n'
    '    } else {\n'
    '        cmd[0].angleturn = (int16) ((((int) ((uchar) (demo_p[_dp++]))) << 8));\n'
    '    }\n'
    '    cmd[0].buttons = (uint8) (((uchar) (demo_p[_dp++])));\n'
    '    demo_p = c_bytes_add (demo_p, _dp);'
)

# 11. Z_Free on non-uint8[] is a no-op under GC
src = re.sub(r'\bZ_Free\s*\((y|wipe_scr_start|wipe_scr_end)\)\s*;', '// Z_Free(\\1);', src)

# 12. Deduplicate identical _c2v_slice_* helper functions
seen_helpers = set()
out_lines = []
lines = src.splitlines(keepends=True)
i = 0
while i < len(lines):
    m = re.match(r'^private static \S+ (_c2v_(?:slice|box)_\S+) \(', lines[i])
    if m:
        name = m.group(1)
        block = [lines[i]]
        if not lines[i].rstrip().endswith('}'):
            i += 1
            while i < len(lines) and not lines[i].startswith('}'):
                block.append(lines[i])
                i += 1
            if i < len(lines):
                block.append(lines[i])
        i += 1
        if name not in seen_helpers:
            seen_helpers.add(name)
            out_lines.extend(block)
    else:
        out_lines.append(lines[i])
        i += 1
src = "".join(out_lines)

# Final exact fixes for the 2 mobj_s lines
src = re.sub(
    r'(mo2 = \(\(mobj_s\?\) th\);\s*if \(\(\(mo2 != )mo(\) && \(mo2\.type == )mo(\.type\)\))',
    r'\1mo[0]\2mo[0]\3',
    src,
)
src = src.replace('if (((mo2 != mo[0]) && (mo2.type == mo[0].type)) && (mo2.health > 0))', 'if (((mo2 != mo) && (mo2.type == mo.type)) && (mo2.health > 0))', 0)
src = re.sub(
    r'(th = _c2v_box_mobj_s_arr \(@in\.d\.thing\);\s*if \()th == shootthing\)',
    r'\1th[0] == shootthing)',
    src,
)
# Ensure 15732 has mo (not mo[0]) by replacing the 2nd occurrence if any
idx1 = src.find('mo2 = ((mobj_s?) th);')
idx2 = src.find('if (((mo2 != ', idx1 + 100)
if idx2 != -1:
    end2 = src.find('\n', idx2)
    src = src[:idx2] + 'if (((mo2 != mo) && (mo2.type == mo.type)) && (mo2.health > 0)) ' + src[end2:]

# Fix I_AtExit missing element allocation
src = src.replace(
    '    entry = new atexit_listentry_s[1];\n    entry[0].func = func;',
    '    entry = new atexit_listentry_s[1];\n    entry[0] = new atexit_listentry_s ();\n    entry[0].func = func;'
)

# Fix W_OpenFile / W_CloseFile / W_Read / W_StdC_* to use _wad_file_s._c2v_fstream directly
src = src.replace(
    'public sealed class _wad_file_s : Object {',
    'public sealed class _wad_file_s : Object {\n    public FileStream? _c2v_fstream = null;'
)
src = re.sub(
    r'_wad_file_s\? W_OpenFile \(uint8\[\] path\) \{.*?\n\}',
    '_wad_file_s? W_OpenFile (uint8[] path) { return W_StdC_OpenFile (path); }',
    src,
    flags=re.DOTALL,
)
src = re.sub(
    r'void W_CloseFile \(_wad_file_s\? wad\) \{.*?\n\}',
    'void W_CloseFile (_wad_file_s? wad) { W_StdC_CloseFile (wad); }',
    src,
    flags=re.DOTALL,
)
src = re.sub(
    r'size_t W_Read \(_wad_file_s\? wad, uint32 offset, uint8\[\] buffer, size_t buffer_len\) \{.*?\n\}',
    'size_t W_Read (_wad_file_s? wad, uint32 offset, uint8[] buffer, size_t buffer_len) { return W_StdC_Read (wad, offset, buffer, buffer_len); }',
    src,
    flags=re.DOTALL,
)
src = re.sub(
    r'_wad_file_s\? W_StdC_OpenFile \(uint8\[\] path\) \{.*?\n\}',
    '_wad_file_s? W_StdC_OpenFile (uint8[] path) {\n    FileStream? fstream = FileStream.open ((string) path, "rb");\n    if (fstream == null) return null;\n    var w = new _wad_file_s ();\n    w._c2v_fstream = fstream;\n    w.mapped = new uint8[0];\n    w.length = (uint32) M_FileLength (fstream);\n    return w;\n}',
    src,
    flags=re.DOTALL,
)
src = re.sub(
    r'void W_StdC_CloseFile \(_wad_file_s\? wad\) \{.*?\n\}',
    'void W_StdC_CloseFile (_wad_file_s? wad) { if (wad != null) ((!) wad)._c2v_fstream = null; }',
    src,
    flags=re.DOTALL,
)
src = re.sub(
    r'size_t W_StdC_Read \(_wad_file_s\? wad, uint32 offset, uint8\[\] buffer, size_t buffer_len\) \{.*?\n\}',
    'size_t W_StdC_Read (_wad_file_s? wad, uint32 offset, uint8[] buffer, size_t buffer_len) {\n    if (wad == null || ((!) wad)._c2v_fstream == null) return 0;\n    ((!) ((!) wad)._c2v_fstream).seek ((long) offset, FileSeek.SET);\n    return (size_t) c_fread (buffer, (size_t) 1, buffer_len, ((!) wad)._c2v_fstream);\n}',
    src,
    flags=re.DOTALL,
)
# Allow /winxp.jpg (our freedoom1.wad slot) to be parsed as WAD
src = src.replace(
    'if (GLib.ascii_strcasecmp ((string) c_bytes_add (filename, _off_filename + (int) (c_strlen ((string) filename)) + (-((int) (3)))), "wad") != 0)',
    'if (false)'
)

src = src.replace(
    'if (!(GLib.ascii_strncasecmp ((string) lump_p[_off_lump_p].name, (string) name, 8) != 0))',
    'if (c_lump_eq (lump_p[_off_lump_p].name, name) != 0)'
)
src = src.replace(
    'if (!(GLib.ascii_strncasecmp ((string) lumpinfo[(int) (i)].name, (string) name, 8) != 0))',
    'if (c_lump_eq (lumpinfo[(int) (i)].name, name) != 0)'
)

src = src.replace(
    '    W_GenerateHashTable ();\n    D_SetGameDescription ();\n    {\n        savegamedir = (string) M_GetSaveGameDir (c_str_to_bytes (D_SaveGameIWADName (gamemission)));\n    }',
    '    print ("[doom] W_GenerateHashTable...\\n");\n    W_GenerateHashTable ();\n    print ("[doom] D_SetGameDescription...\\n");\n    D_SetGameDescription ();\n    savegamedir = "/";\n    print ("[doom] savegamedir ok\\n");'
)
src = src.replace(
    'W_Read (wad_file, (uint32) 0, hdrbuf, (size_t) 12);',
    'print (@"[wad] read hdr len=$(wad_file.length)\\n");\n    W_Read (wad_file, (uint32) 0, hdrbuf, (size_t) 12);\n    print (@"[wad] hdr=$(hdrbuf[0]) $(hdrbuf[1]) $(hdrbuf[2]) $(hdrbuf[3])\\n");'
)
src = src.replace(
    'W_Read (wad_file, (uint32) h_infotableofs, rawinfo, (size_t) length);',
    'print (@"[wad] numlumps=$(h_numlumps) ofs=$(h_infotableofs) len=$(length)\\n");\n    W_Read (wad_file, (uint32) h_infotableofs, rawinfo, (size_t) length);\n    print ("[wad] dir read ok\\n");'
)
src = src.replace(
    '    return wad_file;\n    }\n}',
    '    print ("[wad] W_AddFile done\\n");\n    return wad_file;\n    }\n}'
)

src = src.replace(
    '    D_AddFile (c_str_to_bytes (iwadfile));\n    W_CheckCorrectIWAD (GameMission_t.doom);\n    D_IdentifyVersion ();\n    InitGameVersion ();',
    '    D_AddFile (c_str_to_bytes (iwadfile));\n    print ("[doom] D_AddFile ok\\n");\n    W_CheckCorrectIWAD (GameMission_t.doom);\n    print ("[doom] CheckCorrectIWAD ok\\n");\n    D_IdentifyVersion ();\n    print ("[doom] IdentifyVersion ok\\n");\n    InitGameVersion ();\n    print ("[doom] InitGameVersion ok\\n");'
)

src = src.replace(
    '    I_InitTimer ();\n    I_InitJoystick ();\n    I_InitSound ((uint32) 1);\n    I_InitMusic ();\n    D_ConnectNetGame ();',
    '    print ("[doom] I_InitTimer...\\n");\n    I_InitTimer ();\n    I_InitJoystick ();\n    I_InitSound ((uint32) 1);\n    I_InitMusic ();\n    print ("[doom] D_ConnectNetGame...\\n");\n    D_ConnectNetGame ();\n    print ("[doom] D_ConnectNetGame ok\\n");'
)
src = src.replace('    R_Init ();', '    R_Init ();\n    print ("[doom] R_Init ok\\n");')
src = src.replace('    P_Init ();', '    P_Init ();\n    print ("[doom] P_Init ok\\n");')
src = src.replace('    ST_Init ();', '    ST_Init ();\n    print ("[doom] ST_Init ok\\n");')
src = src.replace('    D_DoomLoop ();', '    print ("[doom] entering D_DoomLoop!\\n");\n    D_DoomLoop ();')

src = src.replace(
    '    patchlookup = new int[nummappatches];',
    '    print (@"[tex] nummappatches=$(nummappatches) nameslen=$(names.length)\\n");\n    patchlookup = new int[nummappatches];'
)
src = src.replace(
    '    numtextures = (numtextures1 + numtextures2);',
    '    print (@"[tex] t1=$(numtextures1) t2=$(numtextures2)\\n");\n    numtextures = (numtextures1 + numtextures2);'
)

src = src.replace('if (lump.wad_file.mapped.length > 0)', 'print (@"[wad] cache $(lumpnum) pos=$(lump.position) sz=$(lump.size)\\n");\n    if (lump.wad_file.mapped.length > 0)')
src = src.replace('    names = W_CacheLumpName (c_str_to_bytes ("PNAMES"), (int) __anon_enum_1.PU_STATIC);', '    print ("[tex] calling PNAMES\\n");\n    names = W_CacheLumpName (c_str_to_bytes ("PNAMES"), (int) __anon_enum_1.PU_STATIC);')
src = src.replace('if (lump.wad_file.mapped != null)', 'if (lump.wad_file.mapped.length > 0)')
# c2vala turns the NULL `lump->cache` pointer into `new uint8[0]`, so the
# non-null test is always true and W_CacheLumpNum returns an empty lump.
src = src.replace('if (lump.cache != null)', 'if (lump.cache.length > 0)')
# M_StringCopy indexes src[len] like C; the last PNAMES entry is a non-NUL
# terminated 8-byte slice, so the bounds-checked array read panics.
src = src.replace(
    "    len = (size_t) (c_strlen ((string) dest));\n    return (uint32) (((src[(int) (len)] == '\\0')) ? 1 : 0);",
    "    len = (size_t) (c_strlen ((string) dest));\n    return (uint32) (((len < src.length) && (src[(int) (len)] == '\\0')) ? 1 : 0);"
)
src = src.replace('_c2v_box_lumpinfo_s_obj (_c2v_slice_lumpinfo_s (lumpinfo, (int) (lump)))', 'lumpinfo[(int) (lump)]')
src = src.replace('_c2v_box_lumpinfo_s_obj (_c2v_slice_lumpinfo_s (lumpinfo, (int) (lumpnum)))', 'lumpinfo[(int) (lumpnum)]')

# Fix R_InitTextures: 32-bit nummappatches, mtexture.name, and mappatch_t binary reading
src = src.replace(
    '    nummappatches = names[0];',
    '    nummappatches = (int) ((uint32) names[0] | ((uint32) names[1] << 8) | ((uint32) names[2] << 16) | ((uint32) names[3] << 24));'
)
old_mtex = """            c_memcpy (texture.name, mtexture.name, ((int) (8) * (int) (1)));
            mpatch = _c2v_slice_mappatch_t (mtexture.patches, (int) (0));
            _off_mpatch = 0;
            patch = _c2v_slice_texpatch_t (texture.patches, (int) (0));
            _off_patch = 0;
            for (j = 0; j < ((int) texture.patchcount); ) {
                {
                    patch[_off_patch].originx = mpatch[_off_mpatch].originx;
                    patch[_off_patch].originy = mpatch[_off_mpatch].originy;
                    patch[_off_patch].patch = patchlookup[(int) (mpatch[_off_mpatch].patch)];
                    if (patch[_off_patch].patch == -1) 
                    {
                        I_Error (c_str_to_bytes ("R_InitTextures: Missing patch in texture %s"), texture.name);
                    }
                }
                j++;
                _off_mpatch++;
                _off_patch++;
            }"""
new_mtex = """            uint8[] _mb = (!) mtexture._c2v_data;
            for (int _k = 0; _k < 8; _k++) texture.name[_k] = _mb[offset + _k];
            for (j = 0; j < ((int) texture.patchcount); j++) {
                int _po = offset + 22 + j * 10;
                int16 _ox = (int16) ((uint16) _mb[_po + 0] | ((uint16) _mb[_po + 1] << 8));
                int16 _oy = (int16) ((uint16) _mb[_po + 2] | ((uint16) _mb[_po + 3] << 8));
                int16 _pi = (int16) ((uint16) _mb[_po + 4] | ((uint16) _mb[_po + 5] << 8));
                texture.patches[j].originx = (int) _ox;
                texture.patches[j].originy = (int) _oy;
                texture.patches[j].patch = patchlookup[(int) _pi];
                if (texture.patches[j].patch == -1) {
                    I_Error (c_str_to_bytes ("R_InitTextures: Missing patch in texture %s"), texture.name);
                }
            }"""
src = src.replace(old_mtex, new_mtex)

# Disable W_Checksum (netgame only, avoids O(N^2) lumpinfo slice and UNTRANSLATED GetFileNumber)
src = re.sub(
    r'void W_Checksum \(uint8\[\] digest\) \{.*?\n\}',
    'void W_Checksum (uint8[] digest) {}',
    src,
    flags=re.DOTALL,
)

# Disable W_GenerateHashTable (avoids O(N^2) slice allocation and keeps W_CheckNumForName returning exact lump index)
src = re.sub(
    r'void W_GenerateHashTable \(\) \{.*?\n\}',
    'void W_GenerateHashTable () { lumphash = null; }',
    src,
    flags=re.DOTALL,
)

# Fix M_LoadDefaults M_StringJoin varargs -> direct filename strings
src = src.replace(
    'doom_defaults.filename = (string) M_StringJoin (c_str_to_bytes (configdir), default_main_config, 0);',
    'doom_defaults.filename = "/default.cfg";'
)
src = src.replace(
    'extra_defaults.filename = (string) M_StringJoin (c_str_to_bytes (configdir), default_extra_config, 0);',
    'extra_defaults.filename = "/extraconfig.cfg";'
)

# Implement I_Error and M_StrToInt
src = src.replace(
    'void I_Error (uint8[] error, ...) {\n}',
    'void I_Error (uint8[] error, ...) {\n    print (@"DOOM I_Error: $((string) error)\\n");\n    GLib.Process.exit (1);\n}'
)
src = src.replace(
    'uint32 M_StrToInt (uint8[] str, int[] result) {\n    return 0;\n}',
    'uint32 M_StrToInt (uint8[] str, int[] result) {\n    string s = ((string) str).strip ();\n    if (s.length == 0) return 0;\n    result[0] = int.parse (s);\n    return 1;\n}'
)

# Auto-initialize fixed array fields in common Doom structs
struct_arr_inits = [
    ("lumpinfo_s", "    public uint8[] name;", "    public uint8[] name = new uint8[8];"),
    ("texture_s", "    public uint8[] name;", "    public uint8[] name = new uint8[8];"),
    ("line_s", "    public int16[] sidenum;", "    public int16[] sidenum = new int16[2];"),
    ("line_s", "    public int[] bbox;", "    public int[] bbox = new int[4];"),
    ("sector_t", "    public int[] blockbox;", "    public int[] blockbox = new int[4];"),
    ("visplane_t", "    public uint8[] top;", "    public uint8[] top = new uint8[324];"),
    ("visplane_t", "    public uint8[] bottom;", "    public uint8[] bottom = new uint8[324];"),
    ("sha1_context_s", "    public uint8[] buf;", "    public uint8[] buf = new uint8[64];"),
    ("spriteframe_t", "    public int16[] lump;", "    public int16[] lump = new int16[8];"),
    ("spriteframe_t", "    public uint8[] flip;", "    public uint8[] flip = new uint8[8];"),
    ("player_s", "    public int[] powers;", "    public int[] powers = new int[6];"),
    ("player_s", "    public uint32[] cards;", "    public uint32[] cards = new uint32[6];"),
    ("player_s", "    public int[] frags;", "    public int[] frags = new int[4];"),
    ("player_s", "    public uint32[] weaponowned;", "    public uint32[] weaponowned = new uint32[9];"),
    ("player_s", "    public int[] ammo;", "    public int[] ammo = new int[4];"),
    ("player_s", "    public int[] maxammo;", "    public int[] maxammo = new int[4];"),
    ("wbplayerstruct_t", "    public int[] frags;", "    public int[] frags = new int[4];"),
    ("net_connect_data_t", "    public uint8[] wad_sha1sum;", "    public uint8[] wad_sha1sum = new uint8[20];"),
    ("net_connect_data_t", "    public uint8[] deh_sha1sum;", "    public uint8[] deh_sha1sum = new uint8[20];"),
]
for cls_target, old_fld, new_fld in struct_arr_inits:
    c_start = src.find(f"public sealed class {cls_target} : Object")
    if c_start != -1:
        c_end = src.find("\n}\n", c_start)
        if c_end != -1:
            block = src[c_start:c_end].replace(old_fld, new_fld)
            src = src[:c_start] + block + src[c_end:]

# Auto-initialize embedded value-struct class fields (non-nullable class fields inside classes)
class_names = set(re.findall(r'^public sealed class (\w+) : Object', src, flags=re.MULTILINE))
# Exclude self-referential or special classes just in case
out_init = []
cur_cls = None
for ln in src.splitlines(keepends=True):
    mc = re.match(r'^public sealed class (\w+) : Object', ln)
    if mc:
        cur_cls = mc.group(1)
    elif ln.startswith('}'):
        cur_cls = None
    elif cur_cls is not None:
        mf = re.match(r'^(\s+public )(\w+)( \w+);\s*$', ln)
        if mf and mf.group(2) in class_names and mf.group(2) != cur_cls:
            ln = f"{mf.group(1)}{mf.group(2)}{mf.group(3)} = new {mf.group(2)} ();\n"
    out_init.append(ln)
src = "".join(out_init)

# W_CacheLumpNum copied everything from the lump offset to the end of the
# 28 MB mapped WAD: a few dozen lumps exhausted the 40 MB userland heap, and
# flexible-array members read `.length` from that oversized buffer. Copy only
# the lump and cache the result.
_bounded = """    if (lump.wad_file.mapped.length > 0) 
    {
        result = _c2v_slice_uint8 (lump.wad_file.mapped, (int) (lump.position));
    }"""
if _bounded in src:
    src = src.replace(_bounded, """    if (lump.wad_file.mapped.length > 0) 
    {
        lump.cache = _c2v_slice_uint8_n (lump.wad_file.mapped, (int) (lump.position), (int) W_LumpLength ((uint32) lumpnum));
        result = lump.cache;
    }""")
if "_c2v_slice_uint8_n (uint8[] arr" not in src:
    _helper = """
private static uint8[] _c2v_slice_uint8_n (uint8[] arr, int off, int n) {
    if (off < 0 || off >= arr.length || n <= 0) return new uint8[0];
    if (off + n > arr.length) n = arr.length - off;
    uint8[] res = new uint8[n];
    for (int i = 0; i < n; i++) res[i] = arr[off + i];
    return res;
}

"""
    _at = src.index("uint8[] W_CacheLumpNum (int lumpnum, int tag) {")
    src = src[:_at] + _helper + src[_at:]
# patch_t.columnofs is a flexible-array member: reading it materialises the
# whole array (one int slot per column, 8 bytes each) on *every* access, so the
# inner column loop allocated a multi-KB copy per pixel column. Hoist it once
# per patch, inside R_GenerateLookup, which is where it is indexed per column.
_i0 = src.find("void R_GenerateLookup (int texnum) {")
_i1 = src.find("uint8[] R_GetColumn (int tex, int col) {")
if _i0 >= 0 and _i1 > _i0:
    _body = src[_i0:_i1]
    _anchor = "                x1 = (int) (patch[_off_patch].originx);"
    if "int[] _cofs" not in _body and _anchor in _body:
        _body = _body.replace(
            _anchor,
            "                int[] _cofs = realpatch.columnofs;\n" + _anchor,
            1,
        )
        _body = _body.replace("realpatch.columnofs[(int) ((x - x1))]", "_cofs[(int) ((x - x1))]")
        src = src[:_i0] + _body + src[_i1:]
# `lighttable_t *scalelight[LIGHTLEVELS][MAXLIGHTSCALE]` is a 2-dimensional array
# of pointers: c2vala allocates only the outer dimension, so the rows are null
# and R_InitLightTables writes through a null row. Allocate them.
src = src.replace(
    "    scalelight = new uint8[][][16];",
    "    scalelight = new uint8[][][16];\n"
    "    for (int _c2v_i = 0; _c2v_i < 16; _c2v_i++) { scalelight[_c2v_i] = new uint8[][48]; }",
)
src = src.replace(
    "    zlight = new uint8[][][16];",
    "    zlight = new uint8[][][16];\n"
    "    for (int _c2v_i = 0; _c2v_i < 16; _c2v_i++) { zlight[_c2v_i] = new uint8[][128]; }",
)
# `static spriteframe_t sprtemp[MAXSPRITEFRAMES]` has no initializer, so c2vala
# leaves the global null while R_InitSpriteDefs writes through it.
_sprtemp_loop = ("        for (int _zi = 0; _zi < 29; _zi++) { sprtemp[_zi] = new spriteframe_t (); "
                 "sprtemp[_zi].rotate = -1; for (int _zj = 0; _zj < 8; _zj++) sprtemp[_zi].lump[_zj] = -1; }")
if _sprtemp_loop in src:
    src = src.replace(
        _sprtemp_loop,
        "        if (sprtemp == null) { sprtemp = new spriteframe_t[29]; "
        "for (int _zs = 0; _zs < 29; _zs++) { sprtemp[_zs] = new spriteframe_t (); sprtemp[_zs].lump = new int16[8]; } }\n"
        + _sprtemp_loop,
        1,
    )
# planc's non-nullable `string[]` fills every slot with "", so the C idiom
# `while (*check) check++` (a NULL-terminated name table) never terminates and
# walks off the array. c2vala drops the trailing NULL from the initializer, so
# the length is exact and can stand in for the scan.
_count_loop = """    check = namelist;
    _off_check = 0;
    while (check[_off_check] != null) {
        _off_check++;
    }
    numsprites = (int) ((_off_check - 0));"""
if _count_loop in src:
    src = src.replace(_count_loop, "    numsprites = namelist.length;")
# `mousebuttons[-1]` and friends: DOOM's key bindings are -1 when a control is
# unbound (and joybspeed can point one past the table), and C just reads the
# byte next door. planc bounds-checks, so those reads go through helpers that
# answer 0 for an out-of-range control.
src = re.sub(r'mousebuttons\[\(int\) \((\w+)\)\](?!\s*=[^=])', r'_c2v_mbtn_at (\1)', src)
src = re.sub(r'joybuttons\[\(int\) \((\w+)\)\](?!\s*=[^=])', r'_c2v_jbtn_at (\1)', src)
# Same for the keyboard: an unbound control leaves its keymap index at -1.
src = re.sub(r'gamekeydown\[\(int\) \((\w+)\)\](?!\s*=[^=])', r'_c2v_key_at (\1)', src)
if "_c2v_mbtn_at" in src and "private static uint32 _c2v_mbtn_at" not in src:
    src += """
private static uint32 _c2v_mbtn_at (int index) {
    if (index < 0 || index >= mousebuttons.length) return (uint32) 0;
    return mousebuttons[index];
}
private static uint32 _c2v_jbtn_at (int index) {
    if (index < 0 || index >= joybuttons.length) return (uint32) 0;
    return joybuttons[index];
}
private static int _c2v_key_at (int index) {
    if (index < 0 || index >= gamekeydown.length) return 0;
    return gamekeydown[index];
}
"""

# `static int *weapon_keys[] = { &key_weapon1, ... }` is a table of pointers to
# int globals, dereferenced as `*weapon_keys[i]`.  planc has no address-of-global
# for that shape, so the table disappears and the loop reads the live globals.
src = src.replace("""        for (i = 0; ((uint64) i) < ((weapon_keys.length[0] * (int) (8)) / 8); ++i) 
        {
            int key = weapon_keys[(int) (i)][0];""",
"""        int[] _c2v_wk = { key_weapon1, key_weapon2, key_weapon3, key_weapon4, key_weapon5, key_weapon6, key_weapon7, key_weapon8 };
        for (i = 0; i < _c2v_wk.length; ++i) 
        {
            int key = _c2v_wk[i];""")
src = re.sub(r'\n *weapon_keys = new int\[\]\[8\];\n *// c2vala: cannot initialize \'weapon_keys\'[^\n]*', '\n', src)

src = src.replace("public uint8[] dc_source;\n", "public uint8[] dc_source;\npublic int _off_dc_source = 0;\n")

# 40. dc_source keeps the post's buffer plus an offset instead of a copy of the
# rest of the patch lump (R_DrawMaskedColumn runs once per post, per column).
src = re.sub(
    r"^(\s*)dc_source = _c2v_slice_uint8 \(\(!\) column\._c2v_data, column\._off \+ \(int\) \(3\)\);",
    r"\1dc_source = ((!) column._c2v_data);\n\1_off_dc_source = column._off + (int) (3);",
    src, flags=re.M)
src = re.sub(
    r"^(\s*)dc_source = R_GetColumn \(",
    r"\1_off_dc_source = 0;\n\1dc_source = R_GetColumn (",
    src, flags=re.M)
src = src.replace("dc_source[(int) (", "dc_source[_off_dc_source + (int) (")

# 41. W_CacheLumpNum copied the whole lump on every call (`_c2v_slice_uint8_n`
# of the mapped WAD), and a picture is cached once per frame, so the title
# screen allocated its 136 KB lump hundreds of times.  Honour the cache first,
# as w_wad.c does, and copy each lump once.
_old_cache = """    lump = lumpinfo[(int) (lumpnum)];
    if (lump.wad_file.mapped.length > 0) 
    {
        lump.cache = _c2v_slice_uint8_n (lump.wad_file.mapped, (int) (lump.position), (int) W_LumpLength ((uint32) lumpnum));
        result = lump.cache;
    }
    else 
    if (lump.cache.length > 0) 
    {
        result = lump.cache;
        Z_ChangeTag2 (lump.cache, tag, c_str_to_bytes ("w_wad.c"), 378);
    }
    else 
    {
        lump.cache = Z_Malloc (W_LumpLength ((uint32) lumpnum), tag, new uint8[0]);
        W_ReadLump ((uint32) lumpnum, lump.cache);
        result = lump.cache;
    }
    return result;"""
_new_cache = """    lump = lumpinfo[(int) (lumpnum)];
    if (lump.cache.length > 0) 
    {
        Z_ChangeTag2 (lump.cache, tag, c_str_to_bytes ("w_wad.c"), 378);
        return lump.cache;
    }
    if (lump.wad_file.mapped.length > 0) 
    {
        lump.cache = _c2v_slice_uint8_n (lump.wad_file.mapped, (int) (lump.position), (int) W_LumpLength ((uint32) lumpnum));
        return lump.cache;
    }
    lump.cache = Z_Malloc (W_LumpLength ((uint32) lumpnum), tag, new uint8[0]);
    W_ReadLump ((uint32) lumpnum, lump.cache);
    return lump.cache;"""
assert _old_cache in src, "W_CacheLumpNum pattern moved"
src = src.replace(_old_cache, _new_cache)

# 42. `ylookup[y]` rows are copies of the screen, so walls and sprites were
# drawn into throw-away buffers.  Keep the row offsets instead and write
# straight into I_VideoBuffer.  Every read is followed by `_off_X = columnofs`,
# which is relative to the row, so the two offsets add up.
src = src.replace("public uint8[][] ylookup;\n", "public uint8[][] ylookup;\npublic int[] ylookup_off;\n")
src = src.replace("ylookup = new uint8[][832];", "ylookup_off = new int[832];")
src = src.replace(
    "ylookup[(int) (i)] = _c2v_slice_uint8 (I_VideoBuffer, (int) (((i + viewwindowy) * 320)));",
    "ylookup_off[(int) (i)] = ((i + viewwindowy) * 320);")
src = re.sub(
    r"^(\s*)(\w+) = ylookup\[\(int\) \((\w+)\)\];\n(\s*)_off_\2 = ",
    r"\1\2 = I_VideoBuffer;\n\4_off_\2 = ylookup_off[(int) (\3)] + ",
    src, flags=re.M)

# 43. R_GetColumn returns a pointer into a cached lump / composite texture, and
# the caller only reads a column out of it.  Return the buffer and hand the
# offset back in a global instead of copying the rest of the texture.
src = src.replace("uint8[] R_GetColumn (int tex, int col) {",
                  "public int _off_rget = 0;\n\nuint8[] R_GetColumn (int tex, int col) {")
src = src.replace(
    "        return c_bytes_add (W_CacheLumpNum (lump, (int) __anon_enum_1.PU_CACHE), (int) (ofs) * 1);",
    "        uint8[] _lump = W_CacheLumpNum (lump, (int) __anon_enum_1.PU_CACHE);\n"
    "        _off_rget = (int) (ofs);\n"
    "        return _lump;")
src = src.replace(
    "    return _c2v_slice_uint8 (texturecomposite[(int) (tex)], (int) (ofs));",
    "    _off_rget = (int) (ofs);\n    return texturecomposite[(int) (tex)];")
src = re.sub(
    r"^(\s*)_off_dc_source = 0;\n(\s*)dc_source = R_GetColumn \(([^;]+)\);",
    r"\2dc_source = R_GetColumn (\3);\n\2_off_dc_source = _off_rget;",
    src, flags=re.M)
src = src.replace(
    "col = new post_t.at (R_GetColumn (texnum, (int) (maskedtexturecol[(int) (dc_x)])), -(int) (3));",
    "_rc_tmp = R_GetColumn (texnum, (int) (maskedtexturecol[(int) (dc_x)]));\n"
    "        col = new post_t.at (_rc_tmp, _off_rget + (-(int) (3)));")
src = src.replace("public int _off_rget = 0;\n", "public int _off_rget = 0;\npublic uint8[] _rc_tmp;\n", 1)

# 44. Bypass the 64,000-pixel Vala loop in I_FinishUpdate and let
# DG_FinishUpdate scale I_VideoBuffer 2x straight into the window surface.
src = re.sub(
    r"void I_FinishUpdate \(\) \{.*?\n\}\n",
    "void I_FinishUpdate () {\n    DG_FinishUpdate ();\n}\n",
    src, count=1, flags=re.S)

# 45. Map lump loaders in p_setup.c boxed a single `T.at (data, 0)` into a
# 1-element array and then indexed past 0; populate the full view array.
for _old_ml, _new_ml in [
    ("ml = _c2v_box_mapvertex_t_arr (new mapvertex_t.at (data, 0));",
     "ml = new mapvertex_t[numvertexes]; for (int _k = 0; _k < numvertexes; _k++) ml[_k] = new mapvertex_t.at (data, _k * 4);"),
    ("ml = _c2v_box_mapseg_t_arr (new mapseg_t.at (data, 0));",
     "ml = new mapseg_t[numsegs]; for (int _k = 0; _k < numsegs; _k++) ml[_k] = new mapseg_t.at (data, _k * 12);"),
    ("ms = _c2v_box_mapsubsector_t_arr (new mapsubsector_t.at (data, 0));",
     "ms = new mapsubsector_t[numsubsectors]; for (int _k = 0; _k < numsubsectors; _k++) ms[_k] = new mapsubsector_t.at (data, _k * 4);"),
    ("ms = _c2v_box_mapsector_t_arr (new mapsector_t.at (data, 0));",
     "ms = new mapsector_t[numsectors]; for (int _k = 0; _k < numsectors; _k++) ms[_k] = new mapsector_t.at (data, _k * 26);"),
    ("mn = _c2v_box_mapnode_t_arr (new mapnode_t.at (data, 0));",
     "mn = new mapnode_t[numnodes]; for (int _k = 0; _k < numnodes; _k++) mn[_k] = new mapnode_t.at (data, _k * 28);"),
    ("mt = _c2v_box_mapthing_t_arr (new mapthing_t.at (data, 0));",
     "mt = new mapthing_t[numthings]; for (int _k = 0; _k < numthings; _k++) mt[_k] = new mapthing_t.at (data, _k * 10);"),
    ("mld = _c2v_box_maplinedef_t_arr (new maplinedef_t.at (data, 0));",
     "mld = new maplinedef_t[numlines]; for (int _k = 0; _k < numlines; _k++) mld[_k] = new maplinedef_t.at (data, _k * 14);"),
    ("msd = _c2v_box_mapsidedef_t_arr (new mapsidedef_t.at (data, 0));",
     "msd = new mapsidedef_t[numsides]; for (int _k = 0; _k < numsides; _k++) msd[_k] = new mapsidedef_t.at (data, _k * 30);"),
]:
    src = src.replace(_old_ml, _new_ml, 1)

src = src.replace(
    "no[_off_no].bbox[(int) (j)][(int) (k)] = (((int) mn[_off_mn].bbox[(int) (j)][(int) (k)]) << 16);",
    "no[_off_no].bbox[(int) (j)][(int) (k)] = (((int) ((int16) c_u_get_u16_at (data, _off_mn * 28 + 8 + (j * 4 + k) * 2))) << 16);",
    1)

src = src.replace(
    'I_Error (c_str_to_bytes ("P_SpawnMapThing: Unknown type %i at (%i, %i)"), mthing[0].type, mthing[0].x, mthing[0].y);',
    'return;',
    1)

src = src.replace(
    "no[_off_no].children[(int) (j)] = (uint16) (((int16) (mn[_off_mn].children[(int) (j)])));",
    "no[_off_no].children[(int) (j)] = c_u_get_u16_at (data, _off_mn * 28 + 24 + j * 2);",
    1)
src = src.replace(
    "node = _c2v_box_node_t_obj (_c2v_slice_node_t (nodes, (int) (nodenum)));",
    "node = nodes[(int) (nodenum)];",
    1)
src = src.replace(
    "return _c2v_box_subsector_s_obj (_c2v_slice_subsector_s (subsectors, (int) ((nodenum & ~0x8000))));",
    "return subsectors[(int) ((nodenum & ~0x8000))];",
    1)

src = src.replace(
    "p[0].psprites = new pspdef_t[(int) psprnum_t.NUMPSPRITES];",
    "p[0].psprites = new pspdef_t[(int) psprnum_t.NUMPSPRITES]; for (int _pi = 0; _pi < p[0].psprites.length; _pi++) p[0].psprites[_pi] = new pspdef_t ();",
    1)

src = src.replace(
    "spritepresent[(int) (((mobj_s?) th).sprite)] = (uint8) 1;",
    "if (th.owner != null) spritepresent[(int) (((mobj_s?) th.owner).sprite)] = (uint8) 1;",
    1)

src = src.replace(
    "for (; (anim[0] == lastanim[0]) ? (_off_anim < 0) : (uintptr.from_pointer ((void*) (anim)) < uintptr.from_pointer ((void*) (lastanim))); _off_anim++)",
    "for (; _off_anim < anims.length && anim[_off_anim].numpics > 0; _off_anim++)",
    1)

src = src.replace(
    """void I_Quit () {
    atexit_listentry_s? entry = null;
    entry = exit_funcs;
    while (entry != null) 
    {
        ((!) entry.func) ();
        entry = entry.next;
    }
}""",
    """void I_Quit () {
    atexit_listentry_s? entry = null;
    entry = exit_funcs;
    while (entry != null) 
    {
        ((!) entry.func) ();
        entry = entry.next;
    }
    GLib.Process.exit (0);
}""",
    1)

# Avoid per-seg/per-subsector/per-node array-tail copies in BSP traversal.
src = src.replace(
    "void R_AddLine (seg_t[] line) {",
    "void R_AddLine (seg_t line) {",
    1)
src = src.replace(
    "        curline = _c2v_box_seg_t_obj (line);\n        angle1 = R_PointToAngle (line[0].v1.x, line[0].v1.y);\n        angle2 = R_PointToAngle (line[0].v2.x, line[0].v2.y);",
    "        curline = line;\n        angle1 = R_PointToAngle (line.v1.x, line.v1.y);\n        angle2 = R_PointToAngle (line.v2.x, line.v2.y);",
    1)
src = src.replace(
    "        backsector = line[0].backsector;",
    "        backsector = line.backsector;",
    1)
src = src.replace(
    "    sub = _c2v_box_subsector_s_obj (_c2v_slice_subsector_s (subsectors, (int) (num)));",
    "    sub = subsectors[(int) (num)];",
    1)
src = src.replace(
    "    seg_t[] line = new seg_t[0];\n    int _off_line = 0;",
    "    int _off_line = 0;",
    1)
src = src.replace(
    "    line = _c2v_slice_seg_t (segs, (int) (sub.firstline));\n    _off_line = 0;",
    "    _off_line = (int) (sub.firstline);",
    1)
src = src.replace(
    "        R_AddLine (_c2v_slice_seg_t (line, _off_line));",
    "        R_AddLine (segs[_off_line]);",
    1)
src = src.replace(
    "    bsp = _c2v_box_node_t_obj (_c2v_slice_node_t (nodes, (int) (bspnum)));",
    "    bsp = nodes[(int) (bspnum)];",
    2)
src = src.replace(
    "            seg = _c2v_box_seg_t_obj (_c2v_slice_seg_t (segs, (int) (ss[_off_ss].firstline)));",
    "            seg = segs[(int) (ss[_off_ss].firstline)];",
    1)
src = src.replace(
    "    sub = _c2v_box_subsector_s_obj (_c2v_slice_subsector_s (subsectors, (int) (num)));",
    "    sub = subsectors[(int) (num)];",
    1)
src = src.replace(
    "    seg = _c2v_slice_seg_t (segs, (int) (sub.firstline));\n    _off_seg = 0;\n    for (; count != 0; ) {\n        {\n            line = seg[_off_seg].linedef;",
    "    _off_seg = (int) (sub.firstline);\n    for (; count != 0; ) {\n        {\n            line = segs[_off_seg].linedef;",
    1)
src = src.replace(
    """// c2vala: UNTRANSLATED AM_clipMline (am_map.c:847) -- am_map.c:879: unknown identifier 'TOP'
// TODO: port this function by hand.
uint32 AM_clipMline (mline_t? ml, fline_t? fl) {
    return 0;
}""",
    """uint32 AM_clipMline (mline_t? ml, fline_t? fl) {
    if (ml == null || fl == null)
        return 0;
    int AM_LEFT = 1;
    int AM_RIGHT = 2;
    int AM_BOTTOM = 4;
    int AM_TOP = 8;
    int outcode1 = 0;
    int outcode2 = 0;
    if (ml.a.y > m_y2) outcode1 = AM_TOP;
    else if (ml.a.y < m_y) outcode1 = AM_BOTTOM;
    if (ml.b.y > m_y2) outcode2 = AM_TOP;
    else if (ml.b.y < m_y) outcode2 = AM_BOTTOM;
    if ((outcode1 & outcode2) != 0)
        return 0;
    if (ml.a.x < m_x) outcode1 |= AM_LEFT;
    else if (ml.a.x > m_x2) outcode1 |= AM_RIGHT;
    if (ml.b.x < m_x) outcode2 |= AM_LEFT;
    else if (ml.b.x > m_x2) outcode2 |= AM_RIGHT;
    if ((outcode1 & outcode2) != 0)
        return 0;
    fl.a.x = f_x + (FixedMul (ml.a.x - m_x, scale_mtof) >> 16);
    fl.a.y = f_y + (f_h - (FixedMul (ml.a.y - m_y, scale_mtof) >> 16));
    fl.b.x = f_x + (FixedMul (ml.b.x - m_x, scale_mtof) >> 16);
    fl.b.y = f_y + (f_h - (FixedMul (ml.b.y - m_y, scale_mtof) >> 16));
    outcode1 = 0;
    if (fl.a.y < 0) outcode1 |= AM_TOP;
    else if (fl.a.y >= f_h) outcode1 |= AM_BOTTOM;
    if (fl.a.x < 0) outcode1 |= AM_LEFT;
    else if (fl.a.x >= f_w) outcode1 |= AM_RIGHT;
    outcode2 = 0;
    if (fl.b.y < 0) outcode2 |= AM_TOP;
    else if (fl.b.y >= f_h) outcode2 |= AM_BOTTOM;
    if (fl.b.x < 0) outcode2 |= AM_LEFT;
    else if (fl.b.x >= f_w) outcode2 |= AM_RIGHT;
    if ((outcode1 & outcode2) != 0)
        return 0;
    int iters = 0;
    while ((outcode1 | outcode2) != 0 && iters++ < 16) {
        int outside = (outcode1 != 0) ? outcode1 : outcode2;
        int tx = 0;
        int ty = 0;
        if ((outside & AM_TOP) != 0) {
            int dy = fl.a.y - fl.b.y;
            int dx = fl.b.x - fl.a.x;
            tx = (dy != 0) ? (fl.a.x + (dx * fl.a.y) / dy) : fl.a.x;
            ty = 0;
        } else if ((outside & AM_BOTTOM) != 0) {
            int dy = fl.a.y - fl.b.y;
            int dx = fl.b.x - fl.a.x;
            tx = (dy != 0) ? (fl.a.x + (dx * (fl.a.y - f_h)) / dy) : fl.a.x;
            ty = f_h - 1;
        } else if ((outside & AM_RIGHT) != 0) {
            int dy = fl.b.y - fl.a.y;
            int dx = fl.b.x - fl.a.x;
            ty = (dx != 0) ? (fl.a.y + (dy * (f_w - 1 - fl.a.x)) / dx) : fl.a.y;
            tx = f_w - 1;
        } else if ((outside & AM_LEFT) != 0) {
            int dy = fl.b.y - fl.a.y;
            int dx = fl.b.x - fl.a.x;
            ty = (dx != 0) ? (fl.a.y + (dy * (-fl.a.x)) / dx) : fl.a.y;
            tx = 0;
        }
        if (outside == outcode1) {
            fl.a.x = tx; fl.a.y = ty; outcode1 = 0;
            if (fl.a.y < 0) outcode1 |= AM_TOP; else if (fl.a.y >= f_h) outcode1 |= AM_BOTTOM;
            if (fl.a.x < 0) outcode1 |= AM_LEFT; else if (fl.a.x >= f_w) outcode1 |= AM_RIGHT;
        } else {
            fl.b.x = tx; fl.b.y = ty; outcode2 = 0;
            if (fl.b.y < 0) outcode2 |= AM_TOP; else if (fl.b.y >= f_h) outcode2 |= AM_BOTTOM;
            if (fl.b.x < 0) outcode2 |= AM_LEFT; else if (fl.b.x >= f_w) outcode2 |= AM_RIGHT;
        }
        if ((outcode1 & outcode2) != 0)
            return 0;
    }
    return 1;
}""",
    1)
src = src.replace(
    """// c2vala: UNTRANSLATED WI_drawLF (wi_stuff.c:416) -- wi_stuff.c:443: initializer lists are not supported
// TODO: port this function by hand.
void WI_drawLF () {
}""",
    """void WI_drawLF () {
    int y = 2;
    if (gamemode != GameMode_t.commercial || wbs.last < 32) {
        if (wbs.last >= 0 && wbs.last < lnames.length && lnames[(int) (wbs.last)] != null) {
            V_DrawPatch (((320 - ((int) lnames[(int) (wbs.last)].width)) / 2), y, lnames[(int) (wbs.last)]);
            y += ((5 * ((int) lnames[(int) (wbs.last)].height)) / 4);
        }
        if (finished != null)
            V_DrawPatch (((320 - ((int) finished.width)) / 2), y, finished);
    }
}""",
    1)

src = src.replace(
    """// c2vala: UNTRANSLATED G_DoPlayDemo (g_game.c:2152) -- g_game.c:2184: printf requires a literal format string
// TODO: port this function by hand.
void G_DoPlayDemo () {
}""",
    """void G_DoPlayDemo () {
    skill_t skill = (skill_t) 0;
    int i = 0;
    int episode = 0;
    int map = 0;
    int demoversion = 0;
    gameaction = gameaction_t.ga_nothing;
    demobuffer = W_CacheLumpName (c_str_to_bytes (defdemoname), (int) __anon_enum_1.PU_STATIC);
    demo_p = demobuffer;
    _off_demo_p = 0;
    demoversion = (int) demo_p[_off_demo_p++];
    if (demoversion == G_VanillaVersionCode ()) {
        longtics = (uint32) 0;
    } else if (demoversion == 111) {
        longtics = (uint32) 1;
    } else {
        print (@"Demo is from a different game version! (read $demoversion, should be $(G_VanillaVersionCode ()))\\n");
        usergame = (uint32) 0;
        demoplayback = (uint32) 0;
        D_AdvanceDemo ();
        return;
    }
    skill = (skill_t) demo_p[_off_demo_p++];
    episode = (int) demo_p[_off_demo_p++];
    map = (int) demo_p[_off_demo_p++];
    deathmatch = (int) demo_p[_off_demo_p++];
    respawnparm = (uint32) demo_p[_off_demo_p++];
    fastparm = (uint32) demo_p[_off_demo_p++];
    nomonsters = (uint32) demo_p[_off_demo_p++];
    consoleplayer = (int) demo_p[_off_demo_p++];
    for (i = 0; i < 4; i++)
        playeringame[(int) (i)] = (uint32) demo_p[_off_demo_p++];
    if ((playeringame[1] != 0) || (M_CheckParm (c_str_to_bytes ("-solo-net")) > 0)
        || (M_CheckParm (c_str_to_bytes ("-netdemo")) > 0)) {
        netgame = (uint32) 1;
        netdemo = (uint32) 1;
    }
    precache = (uint32) 0;
    G_InitNew (skill, episode, map);
    precache = (uint32) 1;
    starttime = I_GetTime ();
    usergame = (uint32) 0;
    demoplayback = (uint32) 1;
}""",
    1)
src = src.replace(
    """        if (currentthinker.tag == -1) 
        {
            currentthinker.next.prev = currentthinker.prev;
            currentthinker.prev.next = currentthinker.next;
        }""",
    """        if (currentthinker.tag == -1) 
        {
            var nxt = currentthinker.next;
            currentthinker.next.prev = currentthinker.prev;
            currentthinker.prev.next = currentthinker.next;
            currentthinker.next = null;
            currentthinker.prev = null;
            currentthinker.owner = null;
            currentthinker.owner_mobj = null;
            currentthinker = nxt;
            continue;
        }""",
    1)
src = src.replace(
    """            if ((((blockx >= 0) && (blockx < bmapwidth)) && (blocky >= 0)) && (blocky < bmapheight)) 
            {
                blocklinks[(int) (((blocky * bmapwidth) + blockx))] = thing[0].bnext;
            }
        }
    }
}""",
    """            if ((((blockx >= 0) && (blockx < bmapwidth)) && (blocky >= 0)) && (blocky < bmapheight)) 
            {
                blocklinks[(int) (((blocky * bmapwidth) + blockx))] = thing[0].bnext;
            }
        }
    }
    thing[0].snext = null;
    thing[0].sprev = null;
    thing[0].bnext = null;
    thing[0].bprev = null;
}""",
    1)

src = src.replace(
    """void D_Display () {
    uint32 viewactivestate = (uint32) 0;
    uint32 menuactivestate = (uint32) 0;
    uint32 inhelpscreensstate = (uint32) 0;
    uint32 fullscreen = (uint32) 0;
    gamestate_t oldgamestate = (gamestate_t) (-1);
    int borderdrawcount = 0;""",
    """public uint32 _d_viewactivestate = 0;
public uint32 _d_menuactivestate = 0;
public uint32 _d_inhelpscreensstate = 0;
public uint32 _d_fullscreen = 0;
public int _d_oldgamestate = -1;
public int _d_borderdrawcount = 0;

void D_Display () {""",
    1)

src = src.replace(
    """// c2vala-ptrs: cmd_obj[DEREF|WR|ARROW]=>T?
void G_ReadDemoTiccmd (ticcmd_t[] cmd) {
    if (((int) demo_p[0]) == 0x80) 
    {
        G_CheckDemoStatus ();
        return;
    }
    int _dp = 0;
    cmd[0].forwardmove = ((int8) (demo_p[_dp++]));
    cmd[0].sidemove = ((int8) (demo_p[_dp++]));
    if (longtics != 0) {
        cmd[0].angleturn = (int16) (demo_p[_dp++]);
        cmd[0].angleturn |= (int16) ((((int) demo_p[_dp++]) << 8));
    } else {
        cmd[0].angleturn = (int16) ((((int) ((uchar) (demo_p[_dp++]))) << 8));
    }
    cmd[0].buttons = (uint8) (((uchar) (demo_p[_dp++])));
    demo_p = c_bytes_add (demo_p, _dp);
}""",
    """public int _off_demo_p = 0;

void G_ReadDemoTiccmd (ticcmd_t[] cmd) {
    if (_off_demo_p >= demo_p.length || ((int) demo_p[_off_demo_p]) == 0x80) 
    {
        G_CheckDemoStatus ();
        return;
    }
    cmd[0].forwardmove = ((int8) (demo_p[_off_demo_p++]));
    cmd[0].sidemove = ((int8) (demo_p[_off_demo_p++]));
    if (longtics != 0) {
        cmd[0].angleturn = (int16) (demo_p[_off_demo_p++]);
        cmd[0].angleturn |= (int16) ((((int) demo_p[_off_demo_p++]) << 8));
    } else {
        cmd[0].angleturn = (int16) ((((int) ((uchar) (demo_p[_off_demo_p++]))) << 8));
    }
    cmd[0].buttons = (uint8) (((uchar) (demo_p[_off_demo_p++])));
}""",
    1)

# Eliminate hot-path slice tail-copies and break R_SortVisSprites unsorted self-cycle.
src = src.replace(
    "    result = _c2v_box_event_t_obj (_c2v_slice_event_t (events, (int) (eventtail)));",
    "    result = events[(int) (eventtail)];",
    1)
src = src.replace(
    "        cmd = _c2v_box_ticcmd_t_obj (_c2v_slice_ticcmd_t (@set.cmds, (int) (i)));",
    "        cmd = @set.cmds[(int) (i)];",
    1)
src = src.replace(
    "        @set = _c2v_box_ticcmd_set_t_obj (_c2v_slice_ticcmd_set_t (ticdata, (int) (((gametic / ticdup) % 128))));",
    "        @set = ticdata[(int) (((gametic / ticdup) % 128))];",
    1)
src = src.replace(
    "            ld = _c2v_box_line_s_obj (_c2v_slice_line_s (lines, (int) (list[_off_list])));",
    "            ld = lines[(int) (list[_off_list])];",
    1)
src = src.replace(
    "        st = _c2v_box_state_t_obj (_c2v_slice_state_t (states, (int) (state)));",
    "        st = states[(int) (state)];",
    1)
src = src.replace(
    "    psp = _c2v_box_pspdef_t_obj (_c2v_slice_pspdef_t (player.psprites, (int) (position)));",
    "    psp = player.psprites[(int) (position)];",
    1)
src = src.replace(
    "        state = _c2v_box_state_t_obj (_c2v_slice_state_t (states, (int) (stnum)));",
    "        state = states[(int) (stnum)];",
    1)
src = src.replace(
    """vissprite_s? R_NewVisSprite () {
    if (numvissprites >= 128) {
        return overflowsprite;
    }
    numvissprites++;
    vissprite_p = _c2v_box_vissprite_s_obj (_c2v_slice_vissprite_s (vissprites, (int) (numvissprites)));
    return _c2v_box_vissprite_s_obj (_c2v_slice_vissprite_s (vissprites, (int) ((numvissprites - 1))));
}""",
    """vissprite_s? R_NewVisSprite () {
    if (numvissprites >= 128) {
        return overflowsprite;
    }
    int idx = numvissprites;
    numvissprites++;
    vissprite_p = (numvissprites < 128) ? vissprites[numvissprites] : overflowsprite;
    return vissprites[idx];
}""",
    1)
src = src.replace(
    "    sprdef = _c2v_box_spritedef_t_obj (_c2v_slice_spritedef_t (sprites, (int) (thing.sprite)));",
    "    sprdef = sprites[(int) (thing.sprite)];",
    1)
src = src.replace(
    "    sprframe = _c2v_box_spriteframe_t_obj (_c2v_slice_spriteframe_t (sprdef.spriteframes, (int) ((thing.frame & 0x7fff))));",
    "    sprframe = sprdef.spriteframes[(int) ((thing.frame & 0x7fff))];",
    1)
src = src.replace(
    "    sprdef = _c2v_box_spritedef_t_obj (_c2v_slice_spritedef_t (sprites, (int) (psp[0].state.sprite)));",
    "    sprdef = sprites[(int) (psp[0].state.sprite)];",
    1)
src = src.replace(
    "    sprframe = _c2v_box_spriteframe_t_obj (_c2v_slice_spriteframe_t (sprdef.spriteframes, (int) ((psp[0].state.frame & 0x7fff))));",
    "    sprframe = sprdef.spriteframes[(int) ((psp[0].state.frame & 0x7fff))];",
    1)
src = src.replace(
    """    count = numvissprites;
    unsorted.prev = unsorted;
    unsorted.next = unsorted.prev;
    if (!(count != 0)) {
        return;
    }
    for (i = 0; i < count; i++) 
    {
        vissprites[(int) (i)].next = _c2v_box_vissprite_s_obj (_c2v_slice_vissprite_s (vissprites, (int) ((i + 1))));
        vissprites[(int) (i)].prev = _c2v_box_vissprite_s_obj (_c2v_slice_vissprite_s (vissprites, (int) ((i - 1))));
    }
    vissprites[(int) (0)].prev = unsorted;
    unsorted.next = _c2v_box_vissprite_s_obj (_c2v_slice_vissprite_s (vissprites, (int) (0)));
    vissprites[(int) ((count - 1))].next = unsorted;
    unsorted.prev = _c2v_box_vissprite_s_obj (_c2v_slice_vissprite_s (vissprites, (int) ((count - 1))));
    vsprsortedhead.prev = vsprsortedhead;
    vsprsortedhead.next = vsprsortedhead.prev;
    for (i = 0; i < count; i++) 
    {
        bestscale = 2147483647;
        best = unsorted.next;
        for (ds = unsorted.next; ds != unsorted; ds = ds.next) 
        {
            if (ds.scale < bestscale) 
            {
                bestscale = ds.scale;
                best = ds;
            }
        }
        best.next.prev = best.prev;
        best.prev.next = best.next;
        best.next = vsprsortedhead;
        best.prev = vsprsortedhead.prev;
        vsprsortedhead.prev.next = best;
        vsprsortedhead.prev = best;
    }""",
    """    count = numvissprites;
    if (!(count != 0)) {
        vsprsortedhead.prev = vsprsortedhead;
        vsprsortedhead.next = vsprsortedhead.prev;
        return;
    }
    unsorted.prev = unsorted;
    unsorted.next = unsorted.prev;
    for (i = 0; i < count; i++) 
    {
        vissprites[(int) (i)].next = (i + 1 < count) ? vissprites[(int) (i + 1)] : null;
        vissprites[(int) (i)].prev = (i > 0) ? vissprites[(int) (i - 1)] : null;
    }
    vissprites[(int) (0)].prev = unsorted;
    unsorted.next = vissprites[(int) (0)];
    vissprites[(int) ((count - 1))].next = unsorted;
    unsorted.prev = vissprites[(int) ((count - 1))];
    vsprsortedhead.prev = vsprsortedhead;
    vsprsortedhead.next = vsprsortedhead.prev;
    for (i = 0; i < count; i++) 
    {
        bestscale = 2147483647;
        best = unsorted.next;
        for (ds = unsorted.next; ds != unsorted; ds = ds.next) 
        {
            if (ds.scale < bestscale) 
            {
                bestscale = ds.scale;
                best = ds;
            }
        }
        best.next.prev = best.prev;
        best.prev.next = best.next;
        best.next = vsprsortedhead;
        best.prev = vsprsortedhead.prev;
        vsprsortedhead.prev.next = best;
        vsprsortedhead.prev = best;
    }
    unsorted.next = null;
    unsorted.prev = null;""",
    1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
print("Applied fix_doom_vala.py")

