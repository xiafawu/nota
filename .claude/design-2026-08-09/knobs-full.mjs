const lerp=(a,b,t)=>a+(b-a)*t;
function hsv(h,s,v){h=((h%360)+360)%360/60;const c=v*s,x=c*(1-Math.abs(h%2-1)),m=v-c;
 const t=[[c,x,0],[x,c,0],[0,c,x],[0,x,c],[x,0,c],[c,0,x]][Math.floor(h)%6];
 return [(t[0]+m)*255,(t[1]+m)*255,(t[2]+m)*255];}
function rgb2hsv(c){const r=c[0]/255,g=c[1]/255,b=c[2]/255,mx=Math.max(r,g,b),mn=Math.min(r,g,b),
 d=mx-mn;let h=0;if(d){h=mx===r?60*(((g-b)/d)%6):mx===g?60*((b-r)/d+2):60*((r-g)/d+4);}
 return [(h+360)%360, mx?d/mx:0, mx];}
function relLum(c){const f=u=>{u/=255;return u<=.03928?u/12.92:Math.pow((u+.055)/1.055,2.4);};
 return .2126*f(c[0])+.7152*f(c[1])+.0722*f(c[2]);}
const contrast=(a,b)=>{const L=relLum(a),M=relLum(b);return (Math.max(L,M)+.05)/(Math.min(L,M)+.05);};
const hex=h=>[parseInt(h.slice(1,3),16),parseInt(h.slice(3,5),16),parseInt(h.slice(5,7),16)];
const over=(i,b,a)=>[lerp(b[0],i[0],a),lerp(b[1],i[1],a),lerp(b[2],i[2],a)];
const SPOTS=[[.16,.18],[.80,.30],[.30,.54],[.86,.68],[.12,.76],[.58,.88]];
const PAL=[["Meadow",44,[24,104,252]],["Tide",210,[186,252,52]],["Dusk",280,[252,34,342]],
 ["Ink",250,[258,296,214]],["Orchard",60,[32,78,210]],["Harbour",200,[214,165,44]],
 ["Heath",300,[288,116,18]],["Frost",210,[200,268,150]],["Kiln",30,[12,40,230]],
 ["Fern",120,[128,178,28]],["Tidepool",190,[172,246,8]],["Vellum",50,[46,96,224]],
 ["Nocturne",240,[226,276,26]],["Lichen",80,[88,40,250]],["Quarry",190,[208,20,100]],
 ["Bloom",320,[348,292,110]]];
const TIERS=[["Body",1.00,7.0],["Speaker",.78,4.5],["Timestamp",.52,3.0],["Rail",.12,1.2]];
function theme(light,push){
 if(light){const top=lerp(.86,.985,push),bot=lerp(.70,.885,push);
  return {bs:.07,bTop:top,bBot:bot,ss:.28,sv:lerp(.80,.965,push),tilt:.014};}
 const top=lerp(.46,.26,push),bot=lerp(.26,.10,push);
 return {bs:.11,bTop:top,bBot:bot,ss:.40,sv:lerp(.50,.30,push),tilt:.020};}
function field(base,fam,T,flat){
 const sds=SPOTS.map((s,i)=>({u:s[0],v:s[1],r:.17+((i*37)%5)*.013,h:fam[i%fam.length]}));
 const out=[];
 for(let j=0;j<28;j++){const v=j/27;
  for(let i=0;i<28;i++){const u=i/27;
   let c=hsv(base,T.bs,T.bTop-(T.bTop-T.bBot)*v+T.tilt*(.5-u));
   for(const s of sds){const d=Math.hypot(u-s.u,(v-s.v)*.62);
    const w=Math.exp(-(d/s.r)*(d/s.r))*.90,sc=hsv(s.h,T.ss,T.sv);
    c=[lerp(c[0],sc[0],w),lerp(c[1],sc[1],w),lerp(c[2],sc[2],w)];}
   const [hh,ss,vv]=rgb2hsv(c),mid=(T.bTop+T.bBot)/2;
   out.push(hsv(hh,ss,lerp(vv,mid,flat)));}}
 return out;}
function run(light,flat,push,label){
 const T=theme(light,push),ink=hex(light?"#1C1A16":"#EEEAE2");
 let wb=99,bb=0,worstTier={r:99,n:""},satS=0,satN=0,vlo=1,vhi=0,vsum=0;
 for(const [n,base,fam] of PAL){
  const px=field(base,fam,T,flat);let b=99;
  for(const c of px){
   for(const [tn,a,need] of TIERS){const r=contrast(over(ink,c,a),c);
    if(tn==="Body"&&r<b)b=r;
    if(r-need<worstTier.r-(worstTier.need||0)){worstTier={r,need,n:tn+"/"+n};}}
   const [h,s,v]=rgb2hsv(c);satS+=s;satN++;vsum+=v;if(v<vlo)vlo=v;if(v>vhi)vhi=v;}
  if(b<wb)wb=b; if(b>bb)bb=b;}
 console.log(`${label}  body ${wb.toFixed(2)}–${bb.toFixed(2)}  spread ${(bb-wb).toFixed(2)}`+
  `  | tightest ${worstTier.n} ${worstTier.r.toFixed(2)} (needs ${worstTier.need})`+
  `  | field sat ${(satS/satN*100).toFixed(0)}%  V ${(vlo*100).toFixed(0)}–${(vhi*100).toFixed(0)}%`+
  ` (range ${((vhi-vlo)*100).toFixed(1)}pt)`);}
console.log("SOFT-FIELD BAND: sat median 26 (IQR 21-32, peak<=48), V floor>=33, ceiling<=76\n");
for(const L of [true,false]){
 console.log(L?"LIGHT":"DARK");
 run(L,.82,.70," 82/70 ");
 run(L,.90,.90," 90/90 ");
 run(L,.90,.70," 90/70 ");
 run(L,.82,.90," 82/90 ");
 console.log("");}
