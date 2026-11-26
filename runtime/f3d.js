/**
 * f3d-core — the Forge3D core browser runtime.
 *
 * Role: the dependency-free Canvas2D player for f3dc scenes. It owns
 * scene normalisation, the geometry builders, animation evaluation,
 * the create()/auto() player (with its <f3d-view> custom element),
 * and worldTris() for the WebGL2 sidecar.
 *
 * This file is an ES module (Phase 7). Its public API is published as
 * named exports at the bottom of the file; a compatibility footer
 * there also attaches the same names onto globalThis.F3D so classic
 * consumers keep working. A classic (non-module) bundle is produced
 * from the ES modules by tools/build_runtime.mjs.
 *
 * Imports: none. This module is self-contained — every helper it
 * uses (PALETTE/NAMED, the vec/geometry builders, build, animState,
 * normScene, create, worldTris, auto) is defined in this file. The
 * only global it reads is F3D_SCENE, which is scene *data* supplied
 * by the host page, not code from a sibling runtime file, so it is
 * deliberately not converted into an import.
 */
// Forge3D runtime v4.0.0 - dependency-free player for f3dc v2 scenes.
// DECISION: Canvas2D only. It renders with the identical math to the
// Fortran engine (lookAt + perspective, flat per-face normals, Lambert
// 0.25+0.75*diffuse, painter sort by mean depth = extensions.depth_sort),
// so stills are deterministic and match native output. A WebGL1 path is
// deliberately NOT shipped in v1: correct and small beats fast and
// wrong; WebGL acceleration is a later wave. Minified by the Makefile.
// Scene (v2): {objects:[{prim,color,pos,rotate,scale,mirror,size,size3,radius,
// height,segments,material,triangles}],camera,lights,animations,bg,
// width,height}; legacy v1 {triangles:[{v,color}]} also loads.
// Anim closed forms mirror src/animation.f90 exactly (see animState):
// te = loop-mapped t (forever: t mod duration; pingpong: triangle;
// once: clamp), p = clamp(te/duration), ep = ease(p) in {linear,
// smooth: p*p*(3-2p), in: p*p, out: 1-(1-p)^2}. spin: angle =
// speed*t if forever+linear else speed*duration*ep; turn: the latter;
// bob: pos.y += 0.5*sin(2*pi*p); pulse: scale *= 1+0.2*sin(2*pi*p);
// grow: scale *= max(ease(p_once),0.01); orbit (R=2, about Y):
// pos += ((cos(a)-1)*2, 0, sin(a)*2), a = speed*te in degrees;
// move: pos[axis] += speed*duration*ep. Defaults: speed 90,
// duration 5, ease linear, loop forever, axis y.
'use strict';
(function (g) {
var PALETTE=[[220,60,60],[60,220,60],[60,100,240],[240,220,50],[200,80,220],[60,220,220]];
var NAMED={red:PALETTE[0],green:PALETTE[1],blue:PALETTE[2],yellow:PALETTE[3],magenta:PALETTE[4],cyan:PALETTE[5],orange:[240,140,40],purple:[140,80,200],pink:[240,150,190],white:[240,240,240],black:[20,20,25],gray:[140,140,145],grey:[140,140,145]};
var D2R=Math.PI/180;
// ---- small vec helpers (plain [x,y,z] arrays) ----
function v3(v,d){if(v==null)return d.slice();if(typeof v==='number')return[v,v,v];return[+v[0]||0,+v[1]||0,+v[2]||0];}
function sub(a,b){return[a[0]-b[0],a[1]-b[1],a[2]-b[2]];}
function cross(a,b){return[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];}
function dot(a,b){return a[0]*b[0]+a[1]*b[1]+a[2]*b[2];}
function norm(a){var l=Math.hypot(a[0],a[1],a[2]);return l>1e-12?[a[0]/l,a[1]/l,a[2]/l]:[0,0,0];}
function color(c,d){ // -> [r,g,b] 0..255 or null
  if(c==null)return d||null;
  if(typeof c==='string'){if(NAMED[c])return NAMED[c];if(c[0]==='#'){var n=parseInt(c.slice(1),16);return[(n>>16)&255,(n>>8)&255,n&255];}return d||null;}
  if(c.length&&c.every(function(x){return x<=1;}))return c.map(function(x){return Math.round(x*255);});
  return[+c[0]||0,+c[1]||0,+c[2]||0];}
function rgb(c,i){return'rgb('+Math.min(255,Math.max(0,Math.round(c[0]*i)))+','+Math.min(255,Math.max(0,Math.round(c[1]*i)))+','+Math.min(255,Math.max(0,Math.round(c[2]*i)))+')';}
// Rotate p by deg about x, then y, then z is NOT Fortran order; the
// object transform below applies scale, Rz, Rx, Ry, translate, which is
// exactly mat4_compose_trs = T*Ry*Rx*Rz*S from math_3d.f90.
function xform(p,pos,rot,scl){
  var x=p[0]*scl[0],y=p[1]*scl[1],z=p[2]*scl[2],c,s,t;
  c=Math.cos(rot[2]*D2R);s=Math.sin(rot[2]*D2R);t=x*c-y*s;y=x*s+y*c;x=t; // Rz
  c=Math.cos(rot[0]*D2R);s=Math.sin(rot[0]*D2R);t=y*c-z*s;z=y*s+z*c;y=t; // Rx
  c=Math.cos(rot[1]*D2R);s=Math.sin(rot[1]*D2R);t=x*c+z*s;z=-x*s+z*c;x=t; // Ry
  return[x+pos[0],y+pos[1],z+pos[2]];}
function rotAxis(p,axis,deg){ // rotate a position about the origin
  var c=Math.cos(deg*D2R),s=Math.sin(deg*D2R),x=p[0],y=p[1],z=p[2];
  if(axis===0)return[x,y*c-z*s,y*s+z*c];
  if(axis===2)return[x*c-y*s,x*s+y*c,z];
  return[x*c+z*s,y,-x*s+z*c];}
// ---- geometry builders: each returns [[a,b,c,faceIdx],...] ----
// Windings mirror src/mesh.f90 so flat normals match native output.
function tri(o,a,b,c,f,n){var t=[a,b,c,f||0];if(n)t[5]=n;o.push(t);}
function cube(o,s3){var hx=s3[0]/2,hy=s3[1]/2,hz=s3[2]/2,
  p=[[-hx,-hy,-hz],[hx,-hy,-hz],[hx,hy,-hz],[-hx,hy,-hz],[-hx,-hy,hz],[hx,-hy,hz],[hx,hy,hz],[-hx,hy,hz]],
  F=[[0,2,1],[0,3,2],[1,6,5],[1,2,6],[5,7,4],[5,6,7],[4,3,0],[4,7,3],[3,6,2],[3,7,6],[4,1,5],[4,0,1]];
  F.forEach(function(f,i){tri(o,p[f[0]],p[f[1]],p[f[2]],i>>1);});}
function sphere(o,r,seg){seg=Math.max(3,seg|0);var rings=Math.max(2,(seg*3/4)|0),i,j;
  function pt(jj,ii){var ph=Math.PI*jj/rings,th=2*Math.PI*ii/seg;return[r*Math.sin(ph)*Math.cos(th),r*Math.cos(ph),r*Math.sin(ph)*Math.sin(th)];}
  function nr(jj,ii){var ph=Math.PI*jj/rings,th=2*Math.PI*ii/seg;return[Math.sin(ph)*Math.cos(th),Math.cos(ph),Math.sin(ph)*Math.sin(th)];}
  var top=[0,r,0],bot=[0,-r,0],nt=[0,1,0],nb=[0,-1,0];
  for(i=0;i<seg;i++){tri(o,top,pt(1,(i+1)%seg),pt(1,i),0,[nt,nr(1,(i+1)%seg),nr(1,i)]);}
  for(j=1;j<rings-1;j++)for(i=0;i<seg;i++){var a=pt(j,i),b=pt(j,(i+1)%seg),c=pt(j+1,(i+1)%seg),d=pt(j+1,i);
    tri(o,a,b,c,0,[nr(j,i),nr(j,(i+1)%seg),nr(j+1,(i+1)%seg)]);tri(o,a,c,d,0,[nr(j,i),nr(j+1,(i+1)%seg),nr(j+1,i)]);}
  for(i=0;i<seg;i++){tri(o,bot,pt(rings-1,i),pt(rings-1,(i+1)%seg),0,[nb,nr(rings-1,i),nr(rings-1,(i+1)%seg)]);}}
function cylinder(o,r,h,seg,cap){seg=Math.max(3,seg|0);var hh=h/2,i;
  function pt(y,ii){var th=2*Math.PI*ii/seg;return[r*Math.cos(th),y,r*Math.sin(th)];}
  function rn(ii){var th=2*Math.PI*ii/seg;return[Math.cos(th),0,Math.sin(th)];}
  for(i=0;i<seg;i++){var b1=pt(-hh,i),b2=pt(-hh,(i+1)%seg),t1=pt(hh,i),t2=pt(hh,(i+1)%seg),n1=rn(i),n2=rn((i+1)%seg);
    tri(o,b1,t2,b2,0,[n1,n2,n2]);tri(o,b1,t1,t2,0,[n1,n1,n2]);
    if(cap){tri(o,[0,hh,0],t2,t1);tri(o,[0,-hh,0],b1,b2);}}}
function cone(o,r,h,seg,cap){seg=Math.max(3,seg|0);var hh=h/2,apex=[0,hh,0],i;
  function pt(ii){var th=2*Math.PI*ii/seg;return[r*Math.cos(th),-hh,r*Math.sin(th)];}
  function sn(ii){var th=2*Math.PI*ii/seg;return norm([h*Math.cos(th),r,h*Math.sin(th)]);}
  for(i=0;i<seg;i++){var b1=pt(i),b2=pt((i+1)%seg);tri(o,b1,apex,b2,0,[sn(i),sn(i),sn((i+1)%seg)]);if(cap)tri(o,[0,-hh,0],b1,b2);}}
function plane(o,w,d){var a=[-w/2,0,-d/2],b=[w/2,0,-d/2],c=[w/2,0,d/2],e=[-w/2,0,d/2];tri(o,a,c,b);tri(o,a,e,c);tri(o,a,b,c);tri(o,a,c,e);} // double-sided since Wave C (D1): back pair mirrors mesh.f90 create_plane
function pyramid(o,base,h){var hb=base/2,hh=h/2,apex=[0,hh,0],
  p=[[-hb,-hh,-hb],[hb,-hh,-hb],[hb,-hh,hb],[-hb,-hh,hb]],i;
  for(i=0;i<4;i++)tri(o,p[i],apex,p[(i+1)%4]);tri(o,p[3],p[1],p[2]);tri(o,p[3],p[0],p[1]);}
function torus(o,R,tube,seg,tseg){seg=Math.max(3,seg|0);tseg=Math.max(3,tseg|0);var i,j;
  function pt(ii,jj){var th=2*Math.PI*ii/seg,ph=2*Math.PI*jj/tseg,rr=R+tube*Math.cos(ph);return[rr*Math.cos(th),tube*Math.sin(ph),rr*Math.sin(th)];}
  function tn(ii,jj){var th=2*Math.PI*ii/seg,ph=2*Math.PI*jj/tseg;return[Math.cos(ph)*Math.cos(th),Math.sin(ph),Math.cos(ph)*Math.sin(th)];}
  for(i=0;i<seg;i++)for(j=0;j<tseg;j++){var a=pt(i,j),b=pt((i+1)%seg,j),c=pt((i+1)%seg,(j+1)%tseg),d=pt(i,(j+1)%tseg);
    tri(o,a,d,c,0,[tn(i,j),tn(i,(j+1)%tseg),tn((i+1)%seg,(j+1)%tseg)]);tri(o,a,c,b,0,[tn(i,j),tn((i+1)%seg,(j+1)%tseg),tn((i+1)%seg,j)]);}}
function build(obj){ // -> {tris, color|null}
  var o=[],prim=String(obj.prim||'cube').toLowerCase(),size=obj.size!=null?+obj.size:2,
    s3=obj.size3?v3(obj.size3,[size,size,size]):[size,size,size],
    r=obj.radius!=null?+obj.radius:size/2,h=obj.height!=null?+obj.height:size,
    seg=obj.segments!=null?+obj.segments:(prim==='torus'?24:16),cap=obj.capped!==false;
  if(prim==='cube'||prim==='box')cube(o,s3);
  else if(prim==='sphere')sphere(o,r,seg);
  else if(prim==='cylinder')cylinder(o,r,h,seg,cap);
  else if(prim==='cone')cone(o,r,h,seg,cap);
  else if(prim==='plane')plane(o,obj.width!=null?+obj.width:s3[0],obj.depth!=null?+obj.depth:s3[2]);
  else if(prim==='pyramid')pyramid(o,size,h);
  else if(prim==='torus')torus(o,obj.radius!=null?+obj.radius:1,obj.tube!=null?+obj.tube:(obj.rings?size/4:0.35),seg,obj.rings!=null?+obj.rings:12);
  else if(prim==='tris'||obj.triangles)(obj.triangles||[]).forEach(function(t){
    var vs=t.v||t.verts||t.vertices||t;if(vs&&vs.length===3){var e=[v3(vs[0],[0,0,0]),v3(vs[1],[0,0,0]),v3(vs[2],[0,0,0]),0,color(t.color||t.c,null)],nn=t.normals||t[5];
      if(nn&&nn.length===3)e[5]=[v3(nn[0],[0,0,0]),v3(nn[1],[0,0,0]),v3(nn[2],[0,0,0])];o.push(e);}});
  // mirror "x"|"y"|"z" (P3): reflect local vertices + index-5
  // normals across the named axis through the local origin.
  // Baking it here, before xform applies scale/rotation/
  // translation, gives exactly T*Ry*Rx*Rz*S*M, the engine's
  // order. The composed determinant is -det(scale) (rotations
  // have det +1), so when it is negative (det(scale) > 0) swap
  // vertex order b/c -- and the normals entries likewise --
  // so face normals, smooth shading and painter behaviour
  // keep the unmirrored outward convention.
  var sc=v3(obj.scale,[1,1,1]),mi=obj.mirror?'xyz'.indexOf(String(obj.mirror).toLowerCase()):-1;
  if(mi>=0){var flip=sc[0]*sc[1]*sc[2]>0;
    o.forEach(function(t){var k,vv,nn2;
      for(k=0;k<3;k++){vv=t[k].slice();vv[mi]=-vv[mi];t[k]=vv;}
      if(t[5])for(k=0;k<3;k++){nn2=t[5][k].slice();nn2[mi]=-nn2[mi];t[5][k]=nn2;}
      if(flip){vv=t[1];t[1]=t[2];t[2]=vv;
        if(t[5]){nn2=t[5][1];t[5][1]=t[5][2];t[5][2]=nn2;}}});}
  return{tris:o,prim:prim,color:color(obj.color,null),
    pos:v3(obj.pos||obj.position,[0,0,0]),rot:v3(obj.rotate||obj.rotation,[0,0,0]),
    scl:sc,name:obj.name||'',mat:String(obj.material||'lambert').toLowerCase(),
    shading:obj.shading?String(obj.shading).toLowerCase():('sphere,cylinder,cone,capsule,tube,lathe,torus,torusknot'.split(',').indexOf(prim)>=0?'smooth':'flat')};}
function xformN(p,rot,scl){return norm(xform(p,[0,0,0],rot,scl));} // scale->Rz->Rx->Ry, no translate
// ---- animation evaluation: returns modified {pos,rot,scl} ----
function animState(obj,anims,t){
  var pos=obj.pos.slice(),rot=obj.rot.slice(),scl=obj.scl.slice();
  anims.forEach(function(a){
    if(a.target&&a.target!=='all'&&obj.name&&a.target!==obj.name)return;
    var ax='xyz'.indexOf(String(a.axis||'y').toLowerCase());if(ax<0)ax=1;
    var sp=a.speed!=null?+a.speed:90,du=a.duration!=null?+a.duration:5,
      lp=String(a.loop||'forever').toLowerCase(),ez=String(a.ease||'linear').toLowerCase(),
      k=String(a.kind||'spin').toLowerCase(),te,p,ep;
    if(lp==='forever')te=du>0?t%du:t;else if(lp==='pingpong'){if(du<=0)te=0;else{var cy=t%(2*du);te=cy<=du?cy:2*du-cy;}}
    else te=du>0?Math.max(0,Math.min(t,du)):0;
    p=du>0?Math.max(0,Math.min(1,te/du)):0;
    ep=ez==='smooth'?p*p*(3-2*p):ez==='in'?p*p:ez==='out'?1-(1-p)*(1-p):p;
    if(k==='spin')rot[ax]+=(lp==='forever'&&ez==='linear')?sp*t:sp*du*ep;
    else if(k==='turn')rot[ax]+=sp*du*ep;
    else if(k==='bob')pos[1]+=0.5*Math.sin(2*Math.PI*p);
    else if(k==='pulse'){var f=1+0.2*Math.sin(2*Math.PI*p);scl=[scl[0]*f,scl[1]*f,scl[2]*f];}
    else if(k==='grow'){var po=du>0?Math.max(0,Math.min(1,Math.max(0,Math.min(t,du))/du)):0,
      go=ez==='smooth'?po*po*(3-2*po):ez==='in'?po*po:ez==='out'?1-(1-po)*(1-po):po,gf=Math.max(go,0.01);
      scl=[scl[0]*gf,scl[1]*gf,scl[2]*gf];}
    else if(k==='orbit'){var ar=sp*te*D2R;pos[0]+=(Math.cos(ar)-1)*2;pos[2]+=Math.sin(ar)*2;}
    else if(k==='move')pos[ax]+=sp*du*ep;
  });
  return{pos:pos,rot:rot,scl:scl};}
// ---- scene normalisation shared by create() and worldTris():
// legacy v1 {triangles} and {meshes} shapes become {objects}.
function normScene(scene){
  if(scene.triangles&&!scene.objects)scene={objects:[{prim:'tris',triangles:scene.triangles}],bg:scene.bg,camera:scene.camera,lights:scene.lights};
  if(scene.meshes&&!scene.objects)scene.objects=scene.meshes.map(function(m){return{prim:'tris',triangles:(m.triangles||[])};});
  return scene;}
// ---- player ----
function create(el,scene){
  if(typeof el==='string')el=document.querySelector(el);
  var canvas=el&&el.tagName==='CANVAS'?el:null,host=el;
  if(!canvas){canvas=document.createElement('canvas');if(host)host.appendChild(canvas);}
  var ctx=canvas.getContext('2d');
  // Wave 4 transport (ANIM-PLAN 4.4): the compiled viewer bootstrap
  // may carry a timeline descriptor {duration, fps, frames} on the
  // scene (scene.timeline, or scene.viewer.timeline), or as the
  // F3D_TIMELINE global next to F3D_SCENE. Capture it before
  // normScene(), whose legacy conversions rebuild the scene object.
  // The IR shape ({fps:{num,den}, duration_frames}) is also accepted.
  var tlDesc=(scene&&(scene.timeline||(scene.viewer&&scene.viewer.timeline)))||g.F3D_TIMELINE||null;
  scene=normScene(scene||g.F3D_SCENE||{objects:[{prim:'cube'}]});
  if(!tlDesc)tlDesc=scene.timeline||(scene.viewer&&scene.viewer.timeline)||null;
  var objs=(scene.objects||[]).map(build);
  var cam=scene.camera||{},eye0=v3(cam.pos||cam.position,[3,2.5,4]),tgt0=v3(cam.target,[0,0,0]),
    up=v3(cam.up,[0,1,0]),fov=cam.fov||60,near=cam.near||0.1,far=cam.far||100;
  var L=(scene.lights&&scene.lights[0])||{},ld=norm(v3(L.direction||L.dir,[-0.5,-1,-0.7])),
    bg=color(scene.bg,[25,25,35])||[25,25,35],anims=scene.animations||scene.anims||[];
  var yaw=0,pitch=0,dist=1,playing=false,raf=0,t0=Date.now(),time=0,destroyed=false,drag=null;
  function bounds(){var mn=[1e9,1e9,1e9],mx=[-1e9,-1e9,-1e9];
    objs.forEach(function(o){o.tris.forEach(function(tr){tr.slice(0,3).forEach(function(p){var w=xform(p,o.pos,o.rot,o.scl);for(var i=0;i<3;i++){if(w[i]<mn[i])mn[i]=w[i];if(w[i]>mx[i])mx[i]=w[i];}});});});
    if(mn[0]>mx[0])return{c:[0,0,0],r:1};
    return{c:[(mn[0]+mx[0])/2,(mn[1]+mx[1])/2,(mn[2]+mx[2])/2],r:Math.max(0.1,Math.hypot(mx[0]-mn[0],mx[1]-mn[1],mx[2]-mn[2])/2)};}
  function autoFrame(){var b=bounds(),d=sub(eye0,tgt0),l=Math.hypot(d[0],d[1],d[2])||1,
    need=b.r/Math.tan(fov*D2R/2)*1.1;dist=Math.max(l,need)/l;tgt0=b.c;eye0=[b.c[0]+d[0]/l*need,b.c[1]+d[1]/l*need,b.c[2]+d[2]/l*need];}
  if(!scene.camera)autoFrame();
  function resize(){var w=(host&&host.clientWidth)||canvas.clientWidth||scene.width||640,
    h=(host&&host.clientHeight)||canvas.clientHeight||scene.height||480;
    if(canvas.width!==w)canvas.width=w;if(canvas.height!==h)canvas.height=h;}
  function eye(){ // orbit offsets: yaw about world Y, pitch about camera right
    var e=sub(eye0,tgt0);e=rotAxis(e,1,yaw);
    var f=norm(sub(tgt0,[tgt0[0]+e[0],tgt0[1]+e[1],tgt0[2]+e[2]])),r=norm(cross(f,up));
    var c=Math.cos(pitch),s=Math.sin(pitch),d=sub([0,0,0],f); // rotate e about r by pitch
    var cr=cross(r,e);e=[e[0]*c+cr[0]*s,e[1]*c+cr[1]*s,e[2]*c+cr[2]*s];void d;
    return[tgt0[0]+e[0]*dist,tgt0[1]+e[1]*dist,tgt0[2]+e[2]*dist];}
  function render(t){
    if(t!=null)time=t;resize();
    var W=canvas.width,H=canvas.height,ep=eye(),
      f=norm(sub(tgt0,ep)),r=norm(cross(f,up)),u=cross(r,f),
      th=Math.tan(fov*D2R/2),asp=W/Math.max(1,H),faces=[];
    ctx.fillStyle=rgb(bg,1);ctx.fillRect(0,0,W,H);
    objs.forEach(function(o){
      var st=animState(o,anims,time);
      o.tris.forEach(function(tr){
        var vs=[],vd=[],dep=0,n,i;
        for(i=0;i<3;i++){var w=xform(tr[i],st.pos,st.rot,st.scl),rel=sub(w,ep),
          vx=dot(r,rel),vy=dot(u,rel),vz=-dot(f,rel); // view space, front = -z
          var cw=-vz;if(cw<near)cw=near;
          vs.push([(vx/(asp*th)/cw+1)*W/2,(1-vy/th/cw)*H/2]);dep+=-vz;vd.push(-vz);}
        var a=vs[0],b=vs[1],cc=vs[2];
        var w0=xform(tr[0],st.pos,st.rot,st.scl),w1=xform(tr[1],st.pos,st.rot,st.scl),w2=xform(tr[2],st.pos,st.rot,st.scl);
        n=norm(cross(sub(w1,w0),sub(w2,w0)));
        var col=tr[4]||o.color||(o.prim==='cube'||o.prim==='box'?PALETTE[tr[3]%6]:[255,255,255]);
        var inten=o.mat==='basic'?1:0.25+0.75*Math.max(0,-dot(n,ld));
        if(o.shading==='smooth'&&tr[5]){ // Gouraud via fixed subdivision: n=4/edge, 16 sub-tris, centroid intensity; sub-tris are separate faces with their own centroid depths
          var vi=tr[5].map(function(q){var wn=xformN(q,st.rot,st.scl);return o.mat==='basic'?1:0.25+0.75*Math.max(0,-dot(wn,ld));}),
            N=4,GP=[],GI=[],GD=[],ii,jj,k;
          for(ii=0;ii<=N;ii++)for(jj=0;jj<=N-ii;jj++){var wA=(N-ii-jj)/N,wB=ii/N,wC=jj/N;
            GP.push([wA*vs[0][0]+wB*vs[1][0]+wC*vs[2][0],wA*vs[0][1]+wB*vs[1][1]+wC*vs[2][1]]);
            GI.push(wA*vi[0]+wB*vi[1]+wC*vi[2]);GD.push(wA*vd[0]+wB*vd[1]+wC*vd[2]);}
          function gi(x,y){return x*(N+1)-x*(x-1)/2+y;}
          function sub3(p,q,s){faces.push({vs:[GP[p],GP[q],GP[s]],dep:(GD[p]+GD[q]+GD[s])/3,col:col,i:(GI[p]+GI[q]+GI[s])/3});}
          for(ii=0;ii<N;ii++)for(jj=0;jj<N-ii;jj++){sub3(gi(ii,jj),gi(ii+1,jj),gi(ii,jj+1));
            if(jj<N-1-ii)sub3(gi(ii+1,jj+1),gi(ii+1,jj),gi(ii,jj+1));}
        }else faces.push({vs:vs,dep:dep/3,col:col,i:inten});});});
    faces.sort(function(a,b){return b.dep-a.dep;}); // painter: far first
    faces.forEach(function(fc){ctx.beginPath();ctx.moveTo(fc.vs[0][0],fc.vs[0][1]);
      ctx.lineTo(fc.vs[1][0],fc.vs[1][1]);ctx.lineTo(fc.vs[2][0],fc.vs[2][1]);ctx.closePath();
      ctx.fillStyle=rgb(fc.col,fc.i);ctx.fill();});
    return api;}
  function loop(){if(!playing||destroyed)return;time=(Date.now()-t0)/1000;render();raf=requestAnimationFrame(loop);}
  // controls: drag orbit, wheel dolly along view dir (via dist), touch drag
  function down(e){drag={x:e.clientX,y:e.clientY};if(canvas.setPointerCapture&&e.pointerId!=null)try{canvas.setPointerCapture(e.pointerId);}catch(_){}}
  function move(e){if(!drag)return;yaw+=(e.clientX-drag.x)*0.5;pitch+=(e.clientY-drag.y)*0.5;
    pitch=Math.max(-89,Math.min(89,pitch));drag={x:e.clientX,y:e.clientY};if(!playing)render();}
  function up2(){drag=null;}
  function wheel(e){e.preventDefault();dist*=Math.exp(e.deltaY*0.001);dist=Math.max(0.05,Math.min(50,dist));if(!playing)render();}
  if(canvas.addEventListener){canvas.addEventListener('pointerdown',down);canvas.addEventListener('pointermove',move);
    canvas.addEventListener('pointerup',up2);canvas.addEventListener('pointercancel',up2);
    canvas.addEventListener('wheel',wheel,{passive:false});canvas.addEventListener('dblclick',function(){yaw=pitch=0;dist=1;if(!playing)render();});}
  // ---- Wave 4 transport helpers (ANIM-PLAN 4.4) ----
  // Effective rate for time->frame: the timeline descriptor's fps
  // first (a plain number, or the IR rational {num, den}, or
  // frames/duration), then scene.fps, then the first animation's
  // fps, then the scene-format default of 30.
  function fpsNow(){
    if(tlDesc){
      if(+tlDesc.fps>0)return +tlDesc.fps;
      if(tlDesc.fps&&+tlDesc.fps.num>0&&+tlDesc.fps.den>0)return +tlDesc.fps.num/+tlDesc.fps.den;
      if(+tlDesc.frames>0&&+tlDesc.duration>0)return +tlDesc.frames/+tlDesc.duration;
      if(+tlDesc.duration_frames>0&&+tlDesc.duration>0)return +tlDesc.duration_frames/+tlDesc.duration;}
    if(+scene.fps>0)return +scene.fps;
    if(anims.length&&+anims[0].fps>0)return +anims[0].fps;
    return 30;}
  // Known duration in seconds, or null when unknown: the timeline
  // descriptor's duration (or its frame count at the effective
  // rate), else scene.duration.
  function durationNow(){
    if(tlDesc){
      if(tlDesc.duration!=null&&isFinite(+tlDesc.duration)&&+tlDesc.duration>=0)return +tlDesc.duration;
      var fr=tlDesc.frames!=null?+tlDesc.frames:+tlDesc.duration_frames;
      if(isFinite(fr)&&fr>=0)return fr/fpsNow();}
    if(scene.duration!=null&&isFinite(+scene.duration)&&+scene.duration>=0)return +scene.duration;
    return null;}
  // Current integer frame. The repo's time->frame derivation is
  // round(t * fps) (the nint rule of f3dc_emit_timeline / the
  // scene-format frame-count rule), never floor.
  function frameNow(){return Math.round(time*fpsNow());}
  // seek(t): set the current time to exactly t, clamped to
  // [0, duration] when a duration is known (otherwise only clamped
  // below at 0). Evaluation is a pure function of absolute t (the
  // Wave-3 evaluator principle), so the seek only assigns `time`
  // and re-bases t0 -- no accumulated state -- and seek(t) twice
  // yields the identical frame. While paused, one frame at t is
  // rendered through the existing paused-render path; while
  // playing, the re-based t0 makes the loop continue from t.
  function seek(t){
    var nt=+t;if(!isFinite(nt))nt=0;
    nt=Math.max(0,nt);
    var du=durationNow();if(du!=null)nt=Math.min(nt,du);
    time=nt;t0=Date.now()-time*1000;
    return render();}
  var api={canvas:canvas,scene:scene,timeline:tlDesc,play:function(){if(!playing){playing=true;t0=Date.now()-time*1000;raf=requestAnimationFrame(loop);}return api;},
    pause:function(){playing=false;if(raf)cancelAnimationFrame(raf);return api;},
    seek:seek,time:function(){return time;},frame:frameNow,
    setTime:function(t){time=t;return render();},render:render,autoFrame:function(){autoFrame();return render();},
    destroy:function(){destroyed=true;api.pause();
      if(canvas.removeEventListener){canvas.removeEventListener('pointerdown',down);canvas.removeEventListener('pointermove',move);canvas.removeEventListener('pointerup',up2);canvas.removeEventListener('wheel',wheel);}}};
  render(0);if(anims.length)api.play();
  if(typeof window!=="undefined")window.F3DViewer=api;
  return api;}
// ---- worldTris(scene, t): flat world-space triangles in the
// core tri format ([a,b,c,faceIdx,color,normals?]) for time t,
// computed with the same build/animState/xform paths render()
// uses, so the WebGL2 sidecar draws exactly what the player
// would. Colours are resolved (per-tri, else object, else the
// cube palette / white rule of render()); index-5 normals are
// carried, rotated by xformN like the smooth-shading path.
function worldTris(scene,t){
  scene=normScene(scene||g.F3D_SCENE||{objects:[{prim:'cube'}]});
  var anims=scene.animations||scene.anims||[],out=[];
  (scene.objects||[]).map(build).forEach(function(o){
    var st=animState(o,anims,t||0);
    o.tris.forEach(function(tr){
      var e=[],i;for(i=0;i<3;i++)e[i]=xform(tr[i],st.pos,st.rot,st.scl);
      e[3]=tr[3];e[4]=tr[4]||o.color||(o.prim==='cube'||o.prim==='box'?PALETTE[tr[3]%6]:[255,255,255]);
      if(tr[5])e[5]=tr[5].map(function(q){return xformN(q,st.rot,st.scl);});
      out.push(e);});});
  return out;}
function auto(scene){
  var el=document.querySelector('f3d-view')||document.querySelector('canvas#f3d-canvas');
  if(!el)return null;
  var fb=document.querySelector('#f3d-fallback');if(fb)fb.style.display='none';
  if(el.tagName!=='CANVAS'&&!el.querySelector('canvas')){/* create() appends one */}
  return create(el,scene||g.F3D_SCENE);}
g.F3D={create:create,auto:auto,worldTris:worldTris,version:'4.0.0'};
// <f3d-view>: uses window.F3D_SCENE, or fetches its src JSON (http only;
// file:// fetch failures are caught and fallback text stays visible).
if(typeof customElements!=='undefined'&&!customElements.get('f3d-view')){
  customElements.define('f3d-view',class extends HTMLElement{
    connectedCallback(){var self=this,go=function(s){self._p=create(self,s);};
      if(this.getAttribute('src'))fetch(this.getAttribute('src')).then(function(r){return r.json();}).then(go).catch(function(){self.textContent='f3d-view: could not load '+self.getAttribute('src');});
      else if(g.F3D_SCENE)go(g.F3D_SCENE);}
    disconnectedCallback(){if(this._p)this._p.destroy();}});}
})(typeof window!=='undefined'?window:globalThis);
// ---- ES module exports + classic compatibility footer (Phase 7) ----
// The IIFE above is unchanged and already published its public API as
// g.F3D = {create, auto, worldTris, version} on window/globalThis.
// Re-export those exact same function objects (and the version
// string) as named module exports — no logic is duplicated here.
const _f3dCore=(typeof window!=='undefined'?window:globalThis).F3D;
const create=_f3dCore.create;
const auto=_f3dCore.auto;
const worldTris=_f3dCore.worldTris;
const version=_f3dCore.version;
export { create, auto, worldTris, version };
// Compatibility footer: attach the same exported names onto
// globalThis.F3D (creating it if absent) so classic consumers that
// expect the global keep working when the classic bundle built by
// tools/build_runtime.mjs is used.
globalThis.F3D=globalThis.F3D||{};
globalThis.F3D.create=create;
globalThis.F3D.auto=auto;
globalThis.F3D.worldTris=worldTris;
globalThis.F3D.version=version;
