/* Sequoya 3s scorecard — shared by the play screen and the leaderboard.
   Gross scores are the source of truth: strokes come from the index,
   the counting (best net) cell and every hole winner are derived. */
(function(){
var HOLES=[
 {n:1,par:4,si:1},{n:2,par:4,si:7},{n:3,par:4,si:3},{n:4,par:3,si:11},{n:5,par:4,si:9},{n:6,par:4,si:17},
 {n:7,par:3,si:5},{n:8,par:5,si:13},{n:9,par:4,si:15},{n:10,par:4,si:10},{n:11,par:3,si:6},{n:12,par:5,si:18},
 {n:13,par:4,si:2},{n:14,par:4,si:8},{n:15,par:3,si:12},{n:16,par:4,si:4},{n:17,par:5,si:16},{n:18,par:4,si:14}];
var PL=[
 {k:'Paul',gets:8,g:[4,5,5,4,4,4,4,6,5,5,5,6,4,5,4,4,6,5]},
 {k:'Dave',gets:12,g:[6,4,6,4,4,5,4,5,5,6,5,7,5,6,4,5,6,5]},
 {k:'Sam', gets:4, g:[5,4,5,4,4,5,4,6,5,4,3,7,5,3,3,5,6,5]},
 {k:'Lee', gets:16,g:[7,6,6,5,5,6,5,6,6,6,4,6,6,6,4,6,7,6]}];
/* which pair a hole belongs to: three-hole matches, pairing order repeating */
var PAIRS=[[['Paul','Dave'],['Sam','Lee']],[['Paul','Sam'],['Dave','Lee']],[['Paul','Lee'],['Dave','Sam']]];
function matchOf(h){return PAIRS[(Math.ceil(h/3)-1)%3]}
function P(k){for(var i=0;i<PL.length;i++)if(PL[i].k===k)return PL[i]}
function stroke(p,i){return HOLES[i].si<=p.gets?1:0}
function net(k,i){var p=P(k);return p.g[i]-stroke(p,i)}
function low(side,i){return net(side[0],i)<=net(side[1],i)?side[0]:side[1]}
function counting(i){var m=matchOf(HOLES[i].n),
  na=Math.min(net(m[0][0],i),net(m[0][1],i)),nb=Math.min(net(m[1][0],i),net(m[1][1],i));
  if(na===nb)return [];                       /* halved hole boxes nothing */
  var w=na<nb?m[0]:m[1],best=Math.min(na,nb);
  return w.filter(function(k){return net(k,i)===best});  /* both if they tie for the win */
}
window.SequoyaScorecard={
  holes:HOLES,players:PL,matchOf:matchOf,net:net,stroke:function(k,i){return stroke(P(k),i)},
  counting:counting,
  gross:function(k,thru){var p=P(k),s=0;for(var i=0;i<(thru||18);i++)s+=p.g[i];return s},
  /* winner of a hole from this pairing's point of view: 'a' | 'b' | null */
  holeWinner:function(i){var m=matchOf(HOLES[i].n),a=net(low(m[0],i),i),b=net(low(m[1],i),i);
    return a<b?'a':b<a?'b':null},
  render:function(el,opt){
    opt=opt||{};var thru=18,played=opt.played!=null?opt.played:18,cw=opt.cellWidth||33;
    var css='<style>.sc-wrap{background:#fff;border:1px solid #DCE5DD;border-radius:12px;overflow:hidden}'+
      '.sc-h{font-family:"Schibsted Grotesk",sans-serif;font-size:12.5px;font-weight:700;padding:9px 11px 7px;display:flex;align-items:baseline}'+
      '.sc-h em{margin-left:auto;font-style:normal;font-size:10px;font-weight:600;color:#5C6B62;letter-spacing:.3px;text-transform:uppercase}'+
      '.sc-scroll{overflow-x:auto;scrollbar-width:none}.sc-scroll::-webkit-scrollbar{display:none}'+
      '.sc-t{border-collapse:separate;border-spacing:0;table-layout:fixed;font-variant-numeric:tabular-nums}'+
      '.sc-t th,.sc-t td{padding:0;text-align:center;font-weight:600}'+
      '.sc-t .lb{position:sticky;left:0;z-index:2;background:#fff;text-align:left;padding:0 8px 0 11px;font-size:11.5px;font-weight:700;white-space:nowrap}'+
      '.sc-t tr.meta .lb{background:#EEF3EF}'+
      '.sc-t tr.meta td,.sc-t tr.meta th{background:#EEF3EF;font-size:11px;height:22px;color:#5C6B62}'+
      '.sc-t tr.hole td,.sc-t tr.hole th{background:#E1EAE2;font-weight:700;color:#0B1F1A;font-size:11px;height:24px}'+
      '.sc-t tr.par td{font-style:italic}'+
      '.sc-t tr.idx td{font-size:10.5px;color:#8B9990}'+
      '.sc-t tr.idx td,.sc-t tr.idx .lb{border-bottom:1px solid #DCE5DD}'+
      '.sc-t tr.p td{height:30px;font-size:12.5px;position:relative}'+
      '.sc-cell{display:inline-flex;align-items:center;justify-content:center;width:'+(cw-7)+'px;height:23px;border-radius:5px;position:relative}'+
      '.sc-cell.cnt{background:#DCF2E4;border:1px solid #7FC79F;color:#0B5B44;font-weight:700}'+
      '.sc-dot{position:absolute;top:-1px;right:-3px;width:4px;height:4px;border-radius:50%;background:#0F6E56}'+
      '.sc-none{color:#C3CFC6}'+
      '.sc-f{display:flex;align-items:center;gap:7px;padding:7px 11px 9px;font-size:10.5px;color:#5C6B62;border-top:1px solid #EDF2EE}'+
      '.sc-f b{color:#0B1F1A}.sc-f .g{margin-left:auto;font-weight:600}</style>';
    var cols='';for(var i=0;i<thru;i++)cols+='<col style="width:'+cw+'px">';
    function row(cls,lb,fn){var r='<tr class="'+cls+'"><td class="lb">'+lb+'</td>';
      for(var i=0;i<thru;i++)r+='<td>'+fn(i)+'</td>';return r+'</tr>'}
    var t='<table class="sc-t"><colgroup><col style="width:52px">'+cols+'</colgroup>'+
      row('meta hole','Hole',function(i){return HOLES[i].n})+
      row('meta par','Par',function(i){return HOLES[i].par})+
      row('meta idx','Index',function(i){return HOLES[i].si})+
      PL.map(function(p){
        return row('p','<span style="color:'+(opt.colour&&opt.colour[p.k]||'#0B1F1A')+'">'+p.k+'</span>',function(i){
          if(i>=played)return '<span class="sc-cell sc-none">&ndash;</span>';
          var c=counting(i),isC=c.indexOf(p.k)>=0,d=stroke(p,i)?'<span class="sc-dot"></span>':'';
          return '<span class="sc-cell'+(isC?' cnt':'')+'">'+p.g[i]+d+'</span>';
        });
      }).join('')+'</table>';
    var foot='<div class="sc-f"><span class="sc-cell cnt" style="width:15px;height:15px"></span>'+
      '<span>won the hole</span><span class="sc-dot" style="position:static;margin-left:3px"></span>'+
      '<span>stroke</span><span class="g">Thru '+played+'</span></div>';
    el.innerHTML=css+'<div class="sc-wrap"><div class="sc-h">Scorecard<em>gross &middot; best net boxed</em></div>'+
      '<div class="sc-scroll">'+t+'</div>'+foot+'</div>';
  }
};
})();
