"""Resource Overhaul terrain-route assets; no deployment.

    py tools/build_mr_terrain_routes.py --selftest
    py tools/build_mr_terrain_routes.py --probe-pack

The probe pack contains the terrain dashes and a cargo indicator. Production packaging
uses assets() and the owning Resource Overhaul generator.

A decal cannot be turned at runtime: the scene's facing argument leaves it as it is (measured
2026-10-22), so every dash direction is its own scene. ParticleOrientation y turns a land decal
(negative is anticlockwise on the map), z turns the SEA_OVERLAY copy (positive is anticlockwise).

The player's line size and colour set (MCT) are scenes too, one per size, colour and direction. The
library holds only the white directions; each scene's small wrapper carries the tint and scale, the
way CA tints quest_ring_decal (Gotrek's and the food merchant's markers) and scales its sea foam. The army supply
lines add three inks (SUPPLY_COLOURS) after the owners' sixteen, so 19 colours in all.
"""
import json
import copy
import re
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
import functools
import io
import struct
import math

import read_vanilla_db as db
from read_pack_index import read

ROOT = Path(__file__).resolve().parents[1]
GAME = Path(db.DB_PACK).parent
OUT = ROOT / 'Modding Files/source/resource_overhaul'
DONOR = b'wh_main_ui_advice_settle_select'
# THE MCT'S COLOUR SETS (author, 2026-10-22): key, label, tooltip, the four owner colours. Picked by the smallest
# CIE76 delta E between two colours of a set under normal vision and simulated deuteranopia, protanopia and
# tritanopia (Machado 2009), lightness 55+ so a line reads on dark land; selftest() measures it again.
COLOUR_SETS = (
    ('default', 'Default', 'Gold, blue, green and red.',
     ((1.0, 0.72, 0.20), (0.25, 0.70, 1.0), (0.40, 1.0, 0.45), (1.0, 0.35, 0.25))),
    ('bright', 'Bright', 'Aqua, violet, yellow and amber: strong colours that stand out from far away.',
     ((0.0, 1.0, 0.8), (0.6, 0.5, 1.0), (1.0, 1.0, 0.0), (0.8, 0.5, 0.1))),
    ('pale', 'Pale', 'Pale blue, pink, cream and sage.',
     ((0.5, 0.8, 1.0), (1.0, 0.7, 0.8), (1.0, 1.0, 0.8), (0.7, 0.8, 0.5))),
    ('colourblind', 'Colour-blind friendly', 'Magenta, teal, red-orange and light yellow: they stay apart for '
     'every common kind of colour blindness.',
     ((0.9, 0.1, 1.0), (0.3, 0.7, 0.7), (1.0, 0.2, 0.0), (1.0, 1.0, 0.7))),
)
OWNER_COLOURS = tuple(rgb for *_text, rgb4 in COLOUR_SETS for rgb in rgb4)   # the owners' palette, set after set
# THE ARMY SUPPLY LINES' THREE INKS (Task 4, 2026-11-08): palette entries 16, 17 and 18, after the owners' sixteen and the
# same in every colour set (terrain_routes.lua R.SUPPLY_INK). Supplied is a cool white, stretched an orange and cut a magenta.
# The first design values (0.92 grey, 1.0/0.62/0.0 and 0.9/0.1/0.9) sat 6.7 to 8.2 delta E from an owner colour in some
# colour-blind view: the grey from the Pale set's cream, the orange from the Default set's gold, the magenta from the
# colour-blind set's own magenta. Each moved the least that clears SUPPLY_APART (0.05, 0.13 and 0.03 in RGB).
SUPPLY_STATES = ('supplied', 'stretched', 'cut')
SUPPLY_COLOURS = ((0.88, 0.92, 0.94), (0.87, 0.61, 0.0), (0.91, 0.10, 0.87))
# Delta E (CIE76, the same four views as the sets) a supply ink keeps from every owner colour of every set, then the
# three states from one another. 10 is as far as sixteen owner colours leave room for: the orange cannot reach 12
# without turning yellow, and nothing within 0.2 of the grey or the magenta reaches 18. The states sit 37 apart.
SUPPLY_APART, SUPPLY_STATES_APART = 10, 30
COLOURS = OWNER_COLOURS + SUPPLY_COLOURS   # the palette: terrain_routes.lua R.ink hands out the first sixteen
# key, label, tooltip, the wrapper's scale on the dash, then on the cargo marker. Small, the default, halved its
# dashes to 0.35 (author, 2026-11-03) and kept the marker at 0.7.
SIZES = (('small', 'Small', 'Thinner, shorter dashes.', 0.35, 0.7),
         ('normal', 'Normal', 'The dashes as designed.', 1.0, 1.0),
         ('large', 'Large', 'Thicker, longer dashes, easier to see from far away.', 1.5, 1.5))
ANGLES = 12          # a dash reads the same both ways, so 12 directions 15 degrees apart cover the half turn
DASH = (1.3, 0.32)   # ParticleScale along and across the route; terrain_routes.lua puts one on every second hex
BOAT_MODEL = 'rigidmodels/derpy_mr_trade_boat.rigid_model_v2'


@functools.lru_cache(None)
def low_poly_model(pack, source):
    """Keep the final native LOD, preserving its mesh materials and vertex format."""
    data=db._unwrap(read(GAME/pack,source)[0][2])
    assert struct.unpack_from('<I',data,4)[0] in (7,8)
    lods=struct.unpack_from('<I',data,8)[0]
    lod=bytearray(data[140+(lods-1)*28:140+lods*28])
    meshes,_,_,offset=struct.unpack_from('<4I',lod)
    at,triangles,vertices=offset,0,0
    bounds=[]
    for _ in range(meshes):
        size,_vo,vc,_io,indices=struct.unpack_from('<5I',data,at+4)
        assert size>48 and at+size<=len(data)
        triangles+=indices//3
        vertices+=vc
        bounds.append(struct.unpack_from('<6f',data,at+24))
        at+=size
    assert 0<meshes<=4 and 0<triangles<=2000, (source,meshes,triangles)
    header=bytearray(data[:140])
    struct.pack_into('<I',header,8,1)
    struct.pack_into('<IfI',lod,12,168,1000.0,0)
    lod[24]=0
    bb=[min(v[i] for v in bounds) for i in range(3)]+[max(v[i] for v in bounds) for i in range(3,6)]
    return bytes(header+lod)+data[offset:at],dict(triangles=triangles,vertices=vertices,meshes=meshes,bounds=bb)


def low_poly_boat():
    model,stats=low_poly_model('models_other.pack','art/campaign/ships/transportship05/nor/nor_transport_ship/nor_transport_ship_01.rigid_model_v2')
    return model,stats['triangles']


def vehicle_config():
    return json.loads((OUT/'trade_vehicles.json').read_text(encoding='utf-8'))


def vehicle_manifest():
    manifest={}
    for key,entry in vehicle_config()['models'].items():
        model,stats=low_poly_model(entry['pack'],entry['source'])
        bb=stats['bounds']
        scale=min(0.8/max(bb[3]-bb[0],bb[5]-bb[2]),0.55/(bb[4]-bb[1]))
        # CA props face wherever their artist left them; `yaw` (degrees, clockwise from above) turns the nose onto +Z.
        assert entry.get('yaw',0)%90==0,key
        manifest[key]=dict(stats,model='rigidmodels/derpy_mr_vehicle_'+key+'.rigid_model_v2',
                           sea=entry['sea'],scale=scale,height=0 if entry['sea'] else -bb[1]*scale,
                           yaw=math.radians(entry.get('yaw',0)))
    return manifest


def scenes():
    """(scene key, library emitter suffix, tint, scale, map angle in degrees or None for the cargo marker)."""
    out = []
    for s, (*_text, scale, marker) in enumerate(SIZES):
        out += [('derpy_mr_route_dash_%d_%d_%d' % (s, c, a), str(a), rgb, scale, a * 180 // ANGLES)
                for c, rgb in enumerate(COLOURS) for a in range(ANGLES)]
        out += [('derpy_mr_route_dash_%d_%d_%d_b%d' % (s, c, a, bend+2), str(a), rgb, scale, a * 180 // ANGLES)
                for c, rgb in enumerate(COLOURS) for a in range(ANGLES) for bend in (-2,-1,1,2)]
        out.append(('derpy_mr_route_cargo_%d' % s, 'cargo', (1.0, 1.0, 1.0), marker, None))
    return out


def library_emitters():
    """(suffix, angle) of each white emitter pair the library holds: the 12 directions and the cargo marker."""
    return list(dict.fromkeys((eid, angle) for _key, eid, _rgb, _scale, angle in scenes()))


def curve_keys(text, values):
    """Set the time-0 key of each named channel's min and max curve, e.g. {'x': '1.3'}."""
    for channel, value in values.items():
        text = re.sub(r'(' + channel + r'_(?:min|max),[^;]+;0\.0,)[^,]+', lambda m: m[1] + str(value), text)
    return text


def assets():
    _, _, data = read(GAME / 'data.pack', 'composite_scene/campaign_advice_settlement_marker.csc')[0]
    scene = db._unwrap(data)
    assert scene.count(DONOR) == 1 and scene[:4] == b'\xca\xab\0\0', 'campaign scene donor changed'
    # The ESF string table is after the node tree: changing this entry's length moves no node offsets.
    # 797 vanilla scenes use this anchor; "free" leaves small effects at the water plane.
    anchor = b'map_zero_y_to_terrain'
    assert scene.count(b'\x04\x00free') == 1
    scene = scene.replace(b'\x04\x00free', struct.pack('<H', len(anchor)) + anchor)
    library = db._unwrap(read(GAME / 'vfx_desc.pack', 'vfx/wh_main_lib_campaign_ui.xml')[0][2])
    text = library.decode('utf-16') if library[:2] == b'\xff\xfe' else library.decode('utf-8-sig')
    native = ET.fromstring('<root>' + text + '</root>')
    out = {}
    from PIL import Image, ImageDraw
    cargo = db._unwrap(read(GAME / 'ui.pack', 'ui/campaign ui/effect_bundles/cargo.png')[0][2])
    # A pill once ParticleScale stretches it DASH[0]:DASH[1], so the round caps are that much narrower here.
    dash, white = Image.new('RGBA', (512, 512)), (255, 255, 255, 255)
    top, bottom, left, right = 52, 460, 26, 486
    cap = round((bottom - top) / 2 * DASH[1] / DASH[0])
    pen = ImageDraw.Draw(dash)
    pen.rectangle((left + cap, top, right - cap, bottom), fill=white)
    pen.ellipse((left, top, left + 2 * cap, bottom), fill=white)
    pen.ellipse((right - 2 * cap, top, right, bottom), fill=white)
    for stem, image in (('cargo', Image.open(io.BytesIO(cargo)).convert('RGBA')), ('dash', dash)):
        out['vfx/textures/derpy_mr_route_' + stem + '.dds'] = campaign_particle_dds(image)
    combined = ET.Element('vfx', **native.find('vfx').attrib)
    for tag in ('emitters', 'behaviour_chains', 'effect_render_stacks'):
        ET.SubElement(combined, tag)
    for eid, angle in library_emitters():
        effect = ET.Element('vfx', revision='2', construction_type='1', enable_in_ted='false',
                            camera_following='false', ref_spawn_speed='-1.00')
        for container, tag in (('emitters', 'emitter'), ('behaviour_chains', 'behaviour_chain'),
                               ('effect_render_stacks', 'effect_render_stack')):
            child = copy.deepcopy(native.find('.//' + tag + '[@id="quest_ring_decal"]'))
            ET.SubElement(effect, container).append(child)
        emitter = effect.find('.//emitter')
        for p in emitter:
            if p.get('name') == 'ParticleScale':
                size = dict(zip('xyz', ('0.90',) * 3 if angle is None else (DASH[0], DASH[1], '0.45')))
                p.text = curve_keys(p.text, size)
            elif p.get('name') in ('ParticleInitialAlpha', 'EmissionRateCurve', 'ParticleLifeTime'):
                value = '2.0' if p.get('name') == 'ParticleLifeTime' else '1.0'
                p.text = re.sub(r'(;0\.0,)[^,]+', lambda m: m[1] + value, p.text)
            elif p.get('name') in ('ParticleSpin_Min', 'ParticleSpin_Max'):
                for axis in 'xyz':
                    p.set(axis, '0.00')
            elif p.get('name') in ('ParticleOrientationMin', 'ParticleOrientationMax') and angle is not None:
                p.set('y', '%.2f' % ((360 - angle) % 360))
        for p in effect.findall('.//modifier[@fragment="vs_vertex_alpha"]/property[@name="curve_alpha"]'):
            p.text = ('alpha_min,8388608,1;0.0,1.0,linear,linear,-0.05,0.0,0.05,0.0,1|'
                      'alpha_max,16711680,1;0.0,1.0,linear,linear,-0.05,0.0,0.05,0.0,1:alpha,0;0,1')
        for p in effect.findall('.//modifier[@fragment="vs_colour"]/property[@name="curve_colour"]'):
            p.text = curve_keys(p.text, dict(zip('rgb', (1.0, 1.0, 1.0))))   # white: the wrapper tints it
        for p in effect.findall('.//texture_property[@name="diffuse"]'):
            p.set('path', 'vfx/textures/derpy_mr_route_' + ('cargo' if angle is None else 'dash') + '.dds')
        for quality in effect.findall('.//behaviour_chain/quality'):
            for p in list(quality):
                if p.get('fragment') == 'vs_cell_texture':
                    quality.remove(p)
        for group in effect:
            for element in group:
                element.set('id', 'dot_' + eid)
                combined.find(group.tag).append(element)
                water = copy.deepcopy(element)
                water.set('id', 'sea_' + eid)
                for p in water.findall('.//property'):
                    if p.get('name') == 'scene_view_type':
                        p.set('value', 'SEA_OVERLAY')
                    elif p.get('name') == 'restriction':
                        p.set('value', '2')
                    elif p.get('name') in ('ParticleOrientationMin', 'ParticleOrientationMax'):
                        p.set('x', '0.00')
                        if angle is not None:
                            p.set('y', '0.00')
                            p.set('z', '%.2f' % angle)
                combined.find(group.tag).append(water)
    prefix = '<shader_library file="fx/particle_vfx_library.hlsl"/>'
    for key, eid, rgb, scale, angle in scenes():
        name = key.ljust(len(DONOR), '_')
        assert len(name) == len(DONOR)
        out['composite_scene/' + name + '.csc'] = scene.replace(DONOR, name.encode('ascii'))
        reference = ET.Element('vfx', revision='2', construction_type='2', enable_in_ted='false',
                               camera_following='false', ref_spawn_speed='-1.00')
        for tag in ('emitters', 'behaviour_chains', 'effect_render_stacks'):
            ET.SubElement(reference, tag)
        refs = ET.Element('vfx_references')
        ref = ET.SubElement(refs, 'vfx', inst_name='main', vfx_ref='derpy_mr_route_library', notes='',
                            scale_min='%.2f' % scale, scale_max='%.2f' % scale, pos_x='0.00', pos_y='0.00', pos_z='0.00',
                            rot_x='0.00', rot_y='0.00', rot_z='0.00', start_time_min='0.00', start_time_max='0.00',
                            infinite_life='true', simulation_speed_multiplier='1.00')
        if '_b' in key:
            bend = int(key.rsplit('_b',1)[1])-2
            offset = 0.7713623046875 / 4 * math.sin(bend * math.pi / 6)
            ref.set('pos_x', '%.6f' % (-math.sin(math.radians(angle))*offset))
            ref.set('pos_z', '%.6f' % (math.cos(math.radians(angle))*offset))
        tint = {'tint_%s_%s' % (end, c): '%g' % v for end in ('min', 'max') for c, v in zip('rgba', rgb + (1,))}
        enabled = ET.SubElement(ref, 'emitter', name='dot_' + eid, enable='true', **tint,
                      particle_lifetime_bias_min='0', particle_lifetime_bias_max='0',
                      emitter_lifetime_bias_min='0', emitter_lifetime_bias_max='0',
                      spawn_rate_scale_factor_min='1', spawn_rate_scale_factor_max='1', sound_record='')
        water = copy.deepcopy(enabled)
        water.set('name', 'sea_' + eid)
        ref.append(water)
        out['vfx/' + name + '.xml'] = (prefix + ET.tostring(reference, encoding='unicode')
                                     + ET.tostring(refs, encoding='unicode')).encode('utf-16')
    out['vfx/derpy_mr_route_library.xml'] = (prefix + ET.tostring(combined, encoding='unicode')).encode('utf-16')
    out['composite_scene/derpy_mr_route_cart.csc'] = cart_asset()
    for turn in range(8):
        out['composite_scene/derpy_mr_route_cart_curve_%d.csc' % turn] = (OUT / ('route_cart_curve_%d.csc' % turn)).read_bytes()
        out['composite_scene/derpy_mr_route_boat_curve_%d.csc' % turn] = (OUT / ('route_boat_curve_%d.csc' % turn)).read_bytes()
    out.update(icon_assets(native))
    out[BOAT_MODEL]=low_poly_boat()[0]
    for key,entry in vehicle_config()['models'].items():
        out['rigidmodels/derpy_mr_vehicle_'+key+'.rigid_model_v2']=low_poly_model(entry['pack'],entry['source'])[0]
        for turn in range(8):
            out['composite_scene/derpy_mr_route_vehicle_%s_%d.csc'%(key,turn)]=(OUT/('route_vehicle_%s_%d.csc'%(key,turn))).read_bytes()
    return out


def icon_assets(native):
    """Use the panel's resource art on a local-space billboard sharing each native cart curve."""
    import gen_mr_ui as G
    from PIL import Image
    out={}
    placeholder=b'derpy_mr_cart_icon_placeholder'
    for stem, _res, path in G.goods():
        key='derpy_mr_cart_icon_'+stem
        staged=ROOT/'Modding Files/pack'/path
        png=staged.read_bytes() if staged.exists() else db._unwrap(read(GAME/'ui.pack',path)[0][2])
        out['vfx/textures/'+key+'.dds']=campaign_particle_dds(Image.open(io.BytesIO(png)).convert('RGBA'))
        effect=ET.Element('vfx',revision='2',construction_type='1',enable_in_ted='false',camera_following='false',ref_spawn_speed='-1.00')
        for container,tag in (('emitters','emitter'),('behaviour_chains','behaviour_chain'),('effect_render_stacks','effect_render_stack')):
            child=copy.deepcopy(native.find('.//'+tag+'[@id="quest_beam"]'))
            child.set('id','icon')
            ET.SubElement(effect,container).append(child)
        emitter=effect.find('.//emitter')
        for p in emitter:
            name=p.get('name')
            if name=='ParticleScale': p.text=curve_keys(p.text,dict.fromkeys('xyz','0.65'))
            elif name=='EmitterPosition': p.text=curve_keys(p.text,dict.fromkeys('xyz','0'))
            elif name=='ParticleInitialAlpha': p.text=curve_keys(p.text,{'x':'1'})
            # Prime the sprite before the scene's first frame; -0.01 left a blank frame at each join.
            elif name=='StartTime': p.set('min','-0.5');p.set('max','-0.5')
            elif name in ('ParticleCullDistances','CullDistances'): p.set('x','0');p.set('y','0');p.set('z','200');p.set('w','200')
        ET.SubElement(emitter,'property',name='ParticleLifeTime',quality='0').text='x_min,8405056,0;0.0,1000000.0,linear,linear,-0.05,0.0,0.05,0.0,1|x_max,16728128,0;0.0,1000000.0,linear,linear,-0.05,0.0,0.05,0.0,1:x,0;0,1'
        ET.SubElement(emitter,'property',name='ParticleDestroyImmediately',quality='0',value='true')
        for q in effect.findall('.//behaviour_chain/quality'):
            for m in list(q):
                if m.get('fragment') in ('vs_cell_texture','ps_soft_edge'): q.remove(m)
        for p in effect.findall('.//texture_property[@name="diffuse"]'): p.set('path','vfx/textures/'+key+'.dds')
        for p in effect.findall('.//property[@name="restriction"]'): p.set('value','0')
        for p in effect.findall('.//property[@name="pre_multiplied_alpha"]'): p.set('value','false')
        for p in effect.findall('.//property[@name="additive_blend_mul"]'): p.set('value','0')
        for p in effect.findall('.//property[@name="emissive"]'): p.set('value','1')
        for p in effect.findall('.//property[@name="curve_alpha"]'):
            p.text='alpha_min,8388608,0;0.0,1.0,linear,linear,-0.05,0.0,0.05,0.0,1|alpha_max,16711680,0;0.0,1.0,linear,linear,-0.05,0.0,0.05,0.0,1:alpha,0;0,1'
        stack=effect.find('.//effect_render_stack')
        ET.SubElement(stack,'property',name='scene_view_type',quality='0',value='FULLRES_DEFERRED_ALPHA')
        out['vfx/'+key+'.xml']=('<shader_library file="fx/particle_vfx_library.hlsl"/>'+ET.tostring(effect,encoding='unicode')).encode('utf-16')
        for turn in range(8):
            scene=(OUT/('route_icon_curve_%d.csc'%turn)).read_bytes()
            assert scene.count(placeholder)==1
            scene=scene.replace(struct.pack('<H',len(placeholder))+placeholder,struct.pack('<H',len(key))+key.encode('ascii'))
            out['composite_scene/derpy_mr_icon_%s_%d.csc'%(stem,turn)]=scene
            sea=(OUT/('route_sea_icon_curve_%d.csc'%turn)).read_bytes()
            assert sea.count(placeholder)==1
            sea=sea.replace(struct.pack('<H',len(placeholder))+placeholder,struct.pack('<H',len(key))+key.encode('ascii'))
            out['composite_scene/derpy_mr_sea_icon_%s_%d.csc'%(stem,turn)]=sea
    return out


def cart_asset():
    # One rigid model with a one-second translation curve; no skeletal animation or sound tracks.
    return (OUT / 'route_cart.csc').read_bytes()


PARTICLE_PX = 512


def campaign_particle_dds(image):
    # All 93 diffuse textures CA's campaign vfx libraries reference are BC7_UNORM_SRGB with full mips.
    # Below PARTICLE_PX our pixels show up inside CA's own particles (braziers, magic, the Hell-Forge panel's
    # fire) as flat squares from campaign load. 2026-10-25, same images: 128 and 256 broken, 512 and 1024 clean.
    # The 2026-10-22 "DXT5 is the cause" fix was wrong; every texture since was 128 px and still broke it.
    import subprocess
    import tempfile
    from PIL import Image
    with tempfile.TemporaryDirectory() as tmp:
        png = Path(tmp) / 'texture.png'
        image.resize((PARTICLE_PX, PARTICLE_PX), Image.Resampling.LANCZOS).save(png)
        subprocess.run([str(ROOT / 'texconv/texconv.exe'), '-nologo', '-y', '-ft', 'dds', '-f', 'BC7_UNORM_SRGB',
                        '-srgb', '-m', '0', '-o', tmp, str(png)], check=True, capture_output=True)
        return next(p for p in Path(tmp).iterdir() if p.suffix.lower() == '.dds').read_bytes()


def dds_header(b):
    height, width, mips = struct.unpack_from('<II', b, 12) + struct.unpack_from('<I', b, 28)
    dxgi = struct.unpack_from('<I', b, 128)[0] if b[84:88] == b'DX10' else None
    return width, height, max(mips, 1), dxgi


def scene_rows():
    _, version, rows = db.load(db.DB_PACK, 'campaign_composite_scenes_tables')[0]
    donor = next(r for r in rows if r['id'] == 'prologue_quest_sub_goal_marker')
    out = []
    for key, *_rest in scenes():
        out.append(dict(donor, filename='composite_scene/' + key.ljust(len(DONOR), '_') + '.csc', id=key))
    out.append(dict(donor, filename='composite_scene/derpy_mr_route_cart.csc', id='derpy_mr_route_cart'))
    for turn in range(8):
        key='derpy_mr_route_cart_curve_%d' % turn
        out.append(dict(donor, filename='composite_scene/'+key+'.csc',id=key))
        key='derpy_mr_route_boat_curve_%d'%turn
        out.append(dict(donor,filename='composite_scene/'+key+'.csc',id=key))
    for key in vehicle_config()['models']:
        for turn in range(8):
            scene='derpy_mr_route_vehicle_%s_%d'%(key,turn)
            out.append(dict(donor,filename='composite_scene/'+scene+'.csc',id=scene))
    import gen_mr_ui as G
    for stem,_res,_icon in G.goods():
        for turn in range(8):
            key='derpy_mr_icon_%s_%d'%(stem,turn)
            out.append(dict(donor,filename='composite_scene/'+key+'.csc',id=key))
            key='derpy_mr_sea_icon_%s_%d'%(stem,turn)
            out.append(dict(donor,filename='composite_scene/'+key+'.csc',id=key))
    return version, list(donor), out


@functools.lru_cache(None)
def grid_header():
    import gen_resource_overhaul as G
    from campaign_route_paths import read_ppd
    alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    sources = [('wh3_main_combi', GAME / 'data_maps.pack', 'wh3_main_combi_map_7'),
               ('wh3_main_chaos', GAME / 'data_maps.pack', 'wh3_main_chaos_map_4')]
    for sub in G.SUBMODS.values():
        pack = Path(sub['pack'])
        if pack.exists():
            candidates = [row['map_name'] for _, _, rows in db.load(pack, 'campaigns_tables')
                          for row in rows if row['campaign_name'] == sub['campaign']]
            if len(set(candidates)) == 1:
                sources.append((sub['campaign'], pack, candidates[0]))
    lines = ['-- GENERATED installed-map navigability; rebuild when the campaign map changes.',
             'DERPY_MR_ROUTE_GRIDS = {']
    for campaign, pack, map_name in sources:
        hits = read(pack, 'campaign_maps/' + map_name + '/pathfinding.ppd')
        if len(hits) != 1:
            raise ValueError('missing or ambiguous pathfinding for ' + campaign)
        data = db._unwrap(hits[0][2])
        grid = read_ppd(data)
        encoded = ''.join(alphabet[n] for n in grid.edges)
        bridges = ','.join('[%d]={%s}' % (y * grid.width + x + 1,
                            ','.join(str(v * grid.width + u + 1) for u, v in sorted(set(ends))))
                           for (x,y), ends in sorted(grid.bridges.items()))
        lines.append('    ["%s"] = {w=%d,h=%d,data=[[%s]],bridges={%s}},'
                     % (campaign, grid.width, grid.height, encoded, bridges))
    lines.append('}\n')
    return '\n'.join(lines)


def runtime():
    profiles=vehicle_config()['cultures']
    header='DERPY_MR_VEHICLE_PROFILES = {\n'+''.join('    [%s]={land=%s,sea=%s},\n'%(json.dumps(k),json.dumps(v['land']),json.dumps(v['sea'])) for k,v in sorted(profiles.items()))+'}\n'
    return grid_header() + header + (OUT / 'terrain_routes.lua').read_text(encoding='utf-8')


def separation(rgb4, other=None):
    """The smallest CIE76 delta E between two of these colours, over normal vision and simulated deuteranopia,
    protanopia and tritanopia (Machado, Oliveira and Fernandes 2009, severity 1, applied in linear RGB). With `other`,
    between one of these and one of those instead."""
    import itertools
    import math
    views = (((1, 0, 0), (0, 1, 0), (0, 0, 1)),
             ((0.367322, 0.860646, -0.227968), (0.280085, 0.672501, 0.047413), (-0.011820, 0.042940, 0.968881)),
             ((0.152286, 1.052583, -0.204868), (0.114503, 0.786281, 0.099216), (-0.003882, -0.048116, 1.051998)),
             ((1.255528, -0.076749, -0.178779), (-0.078411, 0.930809, 0.147602), (0.004733, 0.691367, 0.303900)))

    def lab(rgb, m):
        lin = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb]
        r, g, b = (max(0, min(1, sum(m[i][j] * lin[j] for j in range(3)))) for i in range(3))
        f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
        x, y, z = ((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047, 0.2126 * r + 0.7152 * g + 0.0722 * b,
                   (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883)
        return 116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))
    pairs = list(itertools.combinations(rgb4, 2) if other is None else itertools.product(rgb4, other))
    return min(math.dist(lab(a, m), lab(b, m)) for m in views for a, b in pairs)


def selftest():
    # THE ARMY SUPPLY INKS (Task 4): three palette entries after the owners' sixteen, the same in every colour set.
    # Each is a scene for every size, direction and corner offset: 3 sizes x 3 inks x 12 angles x 5 = 540 more.
    assert OWNER_COLOURS == COLOURS[:16] and COLOURS[16:] == SUPPLY_COLOURS and len(SUPPLY_COLOURS) == 3
    assert len(scenes()) - len(SIZES) * (len(OWNER_COLOURS) * ANGLES * 5 + 1) == 540, 'the supply scenes are 540 more'
    lua = (OUT / 'terrain_routes.lua').read_text(encoding='utf-8')
    ink = re.search(r'^R\.SUPPLY_INK = \{([^}]*)\}$', lua, re.M)
    assert ink and dict(re.findall(r'(\w+) = (\d+)', ink.group(1))) == {
        state: str(len(OWNER_COLOURS) + i) for i, state in enumerate(SUPPLY_STATES)}, 'R.SUPPLY_INK is the palette index of each state'
    # the three states must read apart from each other, and from every owner colour of every set, whoever is looking
    among = separation(SUPPLY_COLOURS)
    assert among >= SUPPLY_STATES_APART, ('the supply states run together', among)
    near = {key: separation(SUPPLY_COLOURS, rgb4) for key, _l, _t, rgb4 in COLOUR_SETS}
    assert min(near.values()) >= SUPPLY_APART, ('a supply ink sits on an owner colour', near)
    # the map keeps each army's answer until R.epoch moves, and F.invalidate_reach is what moves it at a war or a capture
    flows = (OUT / 'flows.lua').read_text(encoding='utf-8')
    reach = re.search(r'^function F\.invalidate_reach\(\)\n(.*?)^end$', flows, re.M | re.S)
    assert reach and 'R.epoch = (R.epoch or 0) + 1' in reach.group(1), 'F.invalidate_reach must move R.epoch (supply_links)'
    # a loaded game sweeps supply ids up to R.SUPPLY_SWEEP: a road has at most the slider's longest reach at the pace in
    # hexes, and the army's own, so a wider slider (or a faster pace) must not outgrow the sweep
    import gen_mr_ui as G
    reach_max = next(row[4] for row in G.SUPPLY_RATES if row[0] == 'supply_reach')
    pace = int(re.search(r'^F\.ROAD_PER_TURN = (\d+)', flows, re.M).group(1))
    sweep = int(re.search(r'^R\.SUPPLY_SWEEP = (\d+)$', lua, re.M).group(1))
    assert sweep >= reach_max * pace + 1, ('R.SUPPLY_SWEEP is shorter than the longest supply road', sweep, reach_max, pace)
    files = assets()
    assert 'composite_scene/derpy_mr_route_cart.csc' in files, 'moving traffic needs its minecart scene'
    count = len(scenes())
    import gen_mr_ui as G
    assert count == len(SIZES) * (len(COLOURS) * ANGLES * 5 + 1) and len(files) == 2 * count + 21 + len(G.goods())*18 + len(vehicle_config()['models'])*9
    boat,triangles=low_poly_boat()
    assert files[BOAT_MODEL]==boat and triangles==688 and len(boat)<40000
    assert struct.unpack_from('<I',boat,8)[0]==1 and struct.unpack_from('<I',boat,152)[0]==168
    manifest=vehicle_manifest()
    assert len(manifest)==32
    assert all(v['land'] in manifest and v['sea'] in manifest for v in vehicle_config()['cultures'].values())
    for key,entry in manifest.items():
        model=files[entry['model']]
        assert struct.unpack_from('<I',model,8)[0]==1
        assert struct.unpack_from('<I',model,152)[0]==168
        assert entry['triangles']<=2000 and entry['meshes']<=4
        # A cart broadside to its road drove sideways in game (2026-10-23). Nose versus tail is set by eye.
        bb=entry['bounds']; along,across=bb[5]-bb[2],bb[3]-bb[0]
        if round(entry['yaw']/(math.pi/2))%2: along,across=across,along
        assert across<=along*1.15,(key,'drives sideways: set its yaw in trade_vehicles.json')
        for turn in range(8):
            scene=files['composite_scene/derpy_mr_route_vehicle_%s_%d.csc'%(key,turn)]
            assert entry['model'].encode('ascii') in scene
            assert (b'\x04\x00free' in scene)==entry['sea']
            assert b'ANIMATION_ELEMENT' not in scene and b'SFX_ELEMENT' not in scene
    assert len(OWNER_COLOURS) == 4 * len(COLOUR_SETS), 'terrain_routes.lua R.colour hands out four colours a set'
    # the label promises it: the colour-blind set keeps its colours furthest apart of all, whoever is looking
    spread = {key: separation(rgb4) for key, _l, _t, rgb4 in COLOUR_SETS}
    assert spread['colourblind'] >= 40 and spread['colourblind'] == max(spread.values()), spread
    for name, b in files.items():
        assert name == name.lower()
        if name.endswith('.dds'):
            width, height, mips, dxgi = dds_header(b)
            assert dxgi == 99, name + ' must be BC7_UNORM_SRGB like every CA campaign particle texture'
            assert width == height >= PARTICLE_PX and width & (width - 1) == 0 and mips == width.bit_length(), (name, width, height, mips)
        elif name.startswith('composite_scene/derpy_mr_route_cart'):
            assert b'\x04\x00free' not in b and b'map_zero_y_to_terrain' in b
            assert b'ANIMATION_ELEMENT' not in b and b'SFX_ELEMENT' not in b and b'linear' in b
            assert b'gen_minecart_medium_anim.rigid_model_v2' in b and b'MODEL_ELEMENT' in b
        elif name.startswith('composite_scene/derpy_mr_route_boat_'):
            assert b'\x04\x00free' in b and b'map_zero_y_to_terrain' not in b
            assert BOAT_MODEL.encode('ascii') in b and b'MODEL_ELEMENT' in b
            assert b'ANIMATION_ELEMENT' not in b and b'SFX_ELEMENT' not in b
        elif name.startswith('composite_scene/derpy_mr_route_vehicle_'):
            assert b'MODEL_ELEMENT' in b and b'linear' in b
        elif name.startswith('composite_scene/derpy_mr_sea_icon_'):
            assert b'\x04\x00free' in b and b'map_zero_y_to_terrain' not in b
            assert b'VFX_ELEMENT' in b and b'MODEL_ELEMENT' not in b and b'placeholder' not in b
        elif name.startswith('composite_scene/derpy_mr_icon_'):
            assert b'VFX_ELEMENT' in b and b'MODEL_ELEMENT' not in b and b'linear' in b
            assert b'map_zero_y_to_terrain' in b and b'placeholder' not in b
        elif name.endswith('.csc'):
            assert DONOR not in b and b.count(b'derpy_mr_route_') == 1
            assert b'\x04\x00free' not in b and b'map_zero_y_to_terrain' in b
        elif name.startswith('vfx/derpy_mr_cart_icon_'):
            root=ET.fromstring('<root>'+b.decode('utf-16')+'</root>')
            assert float(root.find('.//ranged_property[@name="StartTime"]').get('max'))<=-0.5, 'icon must be prewarmed before the first rendered frame'
            assert root.find('.//property[@name="ParticleSimulationSpace"]').get('value')=='LOCAL_SPACE_POSITION_ONLY'
            assert root.find('.//property[@name="restriction"]').get('value')=='0'
            assert root.find('.//property[@name="scene_view_type"]').get('value')=='FULLRES_DEFERRED_ALPHA'
        elif name.endswith('.xml'):
            root = ET.fromstring('<root>' + b.decode('utf-16') + '</root>')
            emitters = root.findall('.//emitter')
            if name.endswith('library.xml'):
                assert root.find('vfx').get('construction_type') == '1', 'local emitters need construction type 1'
                lib = library_emitters()
                assert len(lib) == ANGLES + 1, lib
                ids = {kind + eid for eid, _ in lib for kind in ('dot_', 'sea_')}
                assert len(emitters) == 2 * len(lib) and {e.get('id') for e in emitters} == ids
                assert {p.get('value') for p in root.findall('.//effect_render_stack/property')} == {'DEFERRED_DECAL', 'SEA_OVERLAY'}
                alpha = root.findall('.//modifier[@fragment="vs_vertex_alpha"]/property[@name="curve_alpha"]')
                assert len(alpha) == 6 * len(lib) and all(';0.0,1.0,' in p.text and ';0.1,' not in p.text for p in alpha), 'route particles must be visible immediately'
                # white in the library, or a wrapper's tint multiplies a colour already there
                for p in root.findall('.//modifier[@fragment="vs_colour"]/property[@name="curve_colour"]'):
                    keys = {a: set(re.findall(a + r'_(?:min|max),[^;]+;0\.0,([^,]+)', p.text)) for a in 'rgb'}
                    assert all(keys[a] == {'1.0'} for a in 'rgb'), keys
                for eid, angle in lib:
                    for kind, want in (('dot_', (90, (360 - (angle or 0)) % 360, 0)), ('sea_', (0, 0, angle or 0))):
                        e = root.find('.//emitter[@id="' + kind + eid + '"]')
                        turns = {tuple(round(float(p.get(a))) for a in 'xyz') for p in e
                                 if p.get('name') in ('ParticleOrientationMin', 'ParticleOrientationMax')}
                        assert turns == {want}, (kind + eid, turns, want)
                        scale = next(p.text for p in e if p.get('name') == 'ParticleScale')
                        sizes = {a: set(re.findall(a + r'_(?:min|max),[^;]+;0\.0,([^,]+)', scale)) for a in 'xyz'}
                        want_size = ({'0.90'},) * 3 if angle is None else ({str(DASH[0])}, {str(DASH[1])}, {'0.45'})
                        assert tuple(sizes[a] for a in 'xyz') == want_size, (kind + eid, sizes)
            else:
                assert root.find('vfx').get('construction_type') == '2', 'placed effects need a reference wrapper'
                assert len(emitters) == 2 and all(e.get('enable') == 'true' for e in emitters)
                assert {e.get('name') for e in emitters} <= {e.get('id') for e in ET.fromstring(
                    '<root>' + files['vfx/derpy_mr_route_library.xml'].decode('utf-16') + '</root>').iter('emitter')}
    # every wrapper carries its own scene's colour and size, on the land and the sea copy alike
    for key, eid, rgb, scale, _angle in scenes():
        root = ET.fromstring('<root>' + files['vfx/' + key.ljust(len(DONOR), '_') + '.xml'].decode('utf-16') + '</root>')
        ref = root.find('vfx_references/vfx')
        assert float(ref.get('scale_min')) == float(ref.get('scale_max')) == scale, (key, ref.attrib)
        if '_b' in key:
            bend=int(key.rsplit('_b',1)[1])-2
            amount=0.7713623046875 / 4 * math.sin(bend*math.pi/6)
            assert abs(float(ref.get('pos_x'))+math.sin(math.radians(_angle))*amount)<0.000001
            assert abs(float(ref.get('pos_z'))-math.cos(math.radians(_angle))*amount)<0.000001
        for e in ref.findall('emitter'):
            assert e.get('name') in ('dot_' + eid, 'sea_' + eid), (key, e.get('name'))
            assert tuple(float(e.get('tint_%s_%s' % (end, c))) for end in ('min', 'max') for c in 'rgb') == rgb * 2, key
    # The runtime builds the scene keys itself, in these lists' order; a key with no scene draws nothing, silently.
    lua = (OUT / 'terrain_routes.lua').read_text(encoding='utf-8')
    assert re.search(r'^R\.ANGLES = (\d+)$', lua, re.M).group(1) == str(ANGLES)
    lists = {name: re.findall(r"'([a-z]+)'", re.search(r'^R\.' + name + r' = \{([^}]*)\}$', lua, re.M).group(1))
             for name in ('SIZES', 'SETS')}
    assert lists == {'SIZES': [s[0] for s in SIZES], 'SETS': [c[0] for c in COLOUR_SETS]}, lists
    assert "'derpy_mr_route_dash_' .. size .. '_' .. ink" in lua and "'derpy_mr_route_cargo_' .. size" in lua
    _, _, rows = scene_rows()
    assert len({r['id'] for r in rows}) == count + 17 + len(G.goods())*16 + len(manifest)*8
    assert {r['filename'] for r in rows} <= set(files)
    print('terrain assets: 58 land/sea resource icons on 8 native curves; %d decal scenes plus 9 cart and 8 boat scenes (%d sizes x (%d colours x %d directions x 5 corner offsets + cargo)), a %d-emitter library; '
          'worst-case colour separation %s; supply inks %.1f apart, %s from the sets' % (
              count, len(SIZES), len(COLOURS), ANGLES, 2 * (ANGLES + 1), ', '.join('%s %.1f' % kv for kv in spread.items()),
              among, ', '.join('%s %.1f' % kv for kv in near.items())))


def probe_pack():
    from rpfm_client import call, db as db_kind, ensure_game, new_pack
    folder = ROOT / 'Modding Files/Backup/terrain_routes_20261021/probe'
    folder.mkdir(parents=True, exist_ok=True)
    version, cols, rows = scene_rows()
    table, frag = 'campaign_composite_scenes_tables', 'derpy_mr_route_probe'
    tsv = folder / 'scenes.tsv'
    tsv.write_text('\t'.join(cols) + '\n#' + table + ';' + str(version) + ';db/' + table + '/' + frag + '\n'
                   + '\n'.join('\t'.join(str(r[c]) for c in cols) for r in rows) + '\n', encoding='utf-8')
    ensure_game()
    key = new_pack()
    path = 'db/' + table + '/' + frag
    call('create_file', {'pack': key, 'path': path, 'kind': db_kind(table, version)})
    call('import_tsv', {'pack': key, 'path': path, 'tsv_path': str(tsv)})
    for path, data in assets().items():
        local = folder / path
        local.parent.mkdir(parents=True, exist_ok=True)
        local.write_bytes(data)
        call('add_files_from_disk', {'pack': key, 'paths': [str(local)], 'pack_paths': [path]})
    dest = ROOT / 'Modding Files/Modpacks/derpy_mr_route_probe.pack'
    call('save_pack', {'pack': key, 'path': str(dest)})
    print(dest)


if __name__ == '__main__':
    if sys.argv[1:] == ['--selftest']:
        selftest()
    elif sys.argv[1:] == ['--probe-pack']:
        selftest()
        probe_pack()
    else:
        raise SystemExit(__doc__)
