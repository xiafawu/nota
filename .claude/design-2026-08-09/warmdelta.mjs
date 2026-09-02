const lerp=(a,b,t)=>a+(b-a)*t, clamp=(x,a,b)=>x<a?a:x>b?b:x;
function hsv(h,s,v){h=((h%360)+360)%360/60;const c=v*s,x=c*(1-Math.abs(h%2-1)),m=v-c;
 const t=[[c,x,0],[x,c,0],[0,c,x],[0,x,c],[x,0,c],[c,0,x]][Math.floor(h)%6];
 return [(t[0]+m)*255,(t[1]+m)*255,(t[2]+m)*255];}
function rgb2hsv(c){const r=c[0]/255,g=c[1]/255,b=c[2]/255,mx=Math.max(r,g,b),mn=Math.min(r,g,b),
 d=mx-mn;let h=0;if(d){h=mx===r?60*(((g-b)/d)%6):mx===g?60*((b-r)/d+2):60*((r-g)/d+4);}
 return [(h+360)%360, mx?d/mx:0, mx];}
const WA=40;
function towardWarm(h,w){let d=WA-h;if(d>180)d-=360;if(d<-180)d+=360;return h+d*w;}
const SPOTS=[[.16,.18],[.80,.30],[.30,.54],[.86,.68],[.12,.76],[.58,.88]];
// CIE76-ish deltaE via Lab
function lab(c){const f=u=>{u/=255;u=u<=.04045?u/12.92:Math.pow((u+.055)/1.055,2.4);return u;};
 const r=f(c[0]),g=f(c[1]),b=f(c[2]);
 let X=(.4124*r+.3576*g+.1805*b)/.95047, Y=(.2126*r+.7152*g+.0722*b), Z=(.0193*r+.1192*g+.9505*b)/1.08883;
 const t=u=>u>.008856?Math.cbrt(u):7.787*u+16/116;
 X=t(X);Y=t(Y);Z=t(Z);
 return [116*Y-16, 500*(X-Y), 200*(Y-Z)];}
const dE=(a,b)=>{const A=lab(a),B=lab(b);return Math.hypot(A[0]-B[0],A[1]-B[1],A[2]-B[2]);};

function field(p,w,T,flat){
 const seeds=SPOTS.map((s,i)=>({u:s[0],v:s[1],r:.17+((i*37)%5)*.013,h0:p.fam[i%p.fam.length]}));
 const out=[];
 for(let j=0;j<12;j++){const v=j/11;
  for(let i=0;i<12;i++){const u=i/11;
   const bh=towardWarm(p.base,w*.33);
   let c=hsv(bh,T.bs+w*.03,T.bTop-(T.bTop-T.bBot)*v+T.tilt*(.5-u));
   for(const s of seeds){const d=Math.hypot(u-s.u,(v-s.v)*.62);
    const wt=Math.exp(-(d/s.r)*(d/s.r))*.90;
    const sc=hsv(towardWarm(s.h0,w*.62),T.ss+w*.10,T.sv);
    c=[lerp(c[0],sc[0],wt),lerp(c[1],sc[1],wt),lerp(c[2],sc[2],wt)];}
   const [hh,ss,vv]=rgb2hsv(c),mid=(T.bTop+T.bBot)/2;
   out.push(hsv(hh,ss,lerp(vv,mid,flat)));}}
 return out;}

const PAL=[
 {n:"Meadow",base:44,fam:[24,104,252]},{n:"Tide",base:210,fam:[186,252,52]},
 {n:"Dusk",base:280,fam:[252,34,342]},{n:"Ink",base:250,fam:[258,296,214]},
 {n:"Frost",base:210,fam:[200,268,150]},{n:"Fern",base:120,fam:[128,178,28]},
];
const TL={bs:.07,bTop:.955,bBot:.845,ss:.28,sv:.94,tilt:.014};
const TD={bs:.11,bTop:.30,bBot:.13,ss:.40,sv:.34,tilt:.020};

for(const [nm,T,flat] of [["light flat .82",TL,.82],["dark flat .82",TD,.82],
                          ["light flat .40",TL,.40],["light flat .00",TL,0]]){
 let tot=0,mx=0,rows=[];
 for(const p of PAL){
  const a=field(p,0,T,flat), b=field(p,1,T,flat);
  let s=0,m=0;for(let k=0;k<a.length;k++){const d=dE(a[k],b[k]);s+=d;if(d>m)m=d;}
  s/=a.length; tot+=s; mx=Math.max(mx,m);
  rows.push(`  ${p.n.padEnd(8)} meanDE ${s.toFixed(2).padStart(5)}  maxDE ${m.toFixed(2)}`);}
 console.log(`${nm}:  avg meanDE ${(tot/PAL.length).toFixed(2)}   worst maxDE ${mx.toFixed(2)}`);
 console.log(rows.join("\n"));}
