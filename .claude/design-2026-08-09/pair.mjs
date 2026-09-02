const lerp=(a,b,t)=>a+(b-a)*t;
function hsv(h,s,v){h=((h%360)+360)%360/60;const c=v*s,x=c*(1-Math.abs(h%2-1)),m=v-c;
 const t=[[c,x,0],[x,c,0],[0,c,x],[0,x,c],[x,0,c],[c,0,x]][Math.floor(h)%6];
 return [(t[0]+m)*255,(t[1]+m)*255,(t[2]+m)*255];}
function rgb2hsv(c){const r=c[0]/255,g=c[1]/255,b=c[2]/255,mx=Math.max(r,g,b),mn=Math.min(r,g,b),
 d=mx-mn;let h=0;if(d){h=mx===r?60*(((g-b)/d)%6):mx===g?60*((b-r)/d+2):60*((r-g)/d+4);}
 return [(h+360)%360, mx?d/mx:0, mx];}
const WA=40,towardWarm=(h,w)=>{let d=WA-h;if(d>180)d-=360;if(d<-180)d+=360;return h+d*w;};
const SPOTS=[[.16,.18],[.80,.30],[.30,.54],[.86,.68],[.12,.76],[.58,.88]];
function lab(c){const f=u=>{u/=255;return u<=.04045?u/12.92:Math.pow((u+.055)/1.055,2.4);};
 const r=f(c[0]),g=f(c[1]),b=f(c[2]);
 let X=(.4124*r+.3576*g+.1805*b)/.95047,Y=(.2126*r+.7152*g+.0722*b),Z=(.0193*r+.1192*g+.9505*b)/1.08883;
 const t=u=>u>.008856?Math.cbrt(u):7.787*u+16/116;X=t(X);Y=t(Y);Z=t(Z);
 return [116*Y-16,500*(X-Y),200*(Y-Z)];}
const dE=(a,b)=>{const A=lab(a),B=lab(b);return Math.hypot(A[0]-B[0],A[1]-B[1],A[2]-B[2]);};
function field(p,w,T,flat=.82){
 const seeds=SPOTS.map((s,i)=>({u:s[0],v:s[1],r:.17+((i*37)%5)*.013,h0:p.fam[i%p.fam.length]}));
 const out=[];
 for(let j=0;j<12;j++){const v=j/11;for(let i=0;i<12;i++){const u=i/11;
  let c=hsv(towardWarm(p.base,w*.33),T.bs+w*.03,T.bTop-(T.bTop-T.bBot)*v+T.tilt*(.5-u));
  for(const s of seeds){const d=Math.hypot(u-s.u,(v-s.v)*.62);
   const wt=Math.exp(-(d/s.r)*(d/s.r))*.90;
   const sc=hsv(towardWarm(s.h0,w*.62),T.ss+w*.10,T.sv);
   c=[lerp(c[0],sc[0],wt),lerp(c[1],sc[1],wt),lerp(c[2],sc[2],wt)];}
  const [hh,ss,vv]=rgb2hsv(c),mid=(T.bTop+T.bBot)/2;
  out.push(hsv(hh,ss,lerp(vv,mid,flat)));}}
 return out;}
const meanDE=(a,b)=>{let s=0;for(let k=0;k<a.length;k++)s+=dE(a[k],b[k]);return s/a.length;};
const C={asym:m=>1-Math.exp(-m/9), lin:m=>Math.min(1,m/45), step:m=>m>=60?1:m>=30?.66:m>=15?.33:0};
const P={n:"Frost",base:210,fam:[200,268,150]};
const TL={bs:.07,bTop:.955,bBot:.845,ss:.28,sv:.94,tilt:.014};
console.log("Frost, light.  pane-vs-pane meanDE  (JND ~2.3, obvious ~5)");
console.log("  min   w_asym w_lin w_step |  A-L   A-S   L-S");
for(const m of [1,3,5,10,15,20,30,45,60,90]){
 const f={};for(const k in C) f[k]=field(P,C[k](m),TL);
 console.log(`  ${String(m).padStart(3)}   ${C.asym(m).toFixed(2)}  ${C.lin(m).toFixed(2)}  ${C.step(m).toFixed(2)}  | `+
  `${meanDE(f.asym,f.lin).toFixed(1).padStart(5)} ${meanDE(f.asym,f.step).toFixed(1).padStart(5)} ${meanDE(f.lin,f.step).toFixed(1).padStart(5)}`);}
