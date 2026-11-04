"""User supplied taxonomy; origins are not inferred from brands or seaweed flavor."""
from decimal import Decimal as D
from .catalog import PRODUCTS

# The photograph says 精工饲料盐; preserve that wording rather than silently correcting it.
CATEGORIES=[
 (1,'SALT-FOOD','食用盐',None,1),(2,'SALT-NONFOOD','非食用盐',None,1),(3,'AUX','辅助物料',None,1),
 (11,'SALT-FOOD-PROCESS','食品加工用盐',1,2),(12,'SALT-FOOD-SMALL','小包装',1,2),
 (21,'SALT-NONFOOD-FEED','精工饲料盐',2,2),(22,'SALT-NONFOOD-WET','散湿盐',2,2),
 (23,'SALT-NONFOOD-SEA','海盐散原盐',2,2),(24,'SALT-NONFOOD-MED','药用盐',2,2),(25,'SALT-NONFOOD-SOFT','软水剂',2,2),
 (29,'SALT-NONFOOD-PENDING','品种待确认',2,2),
 (31,'AUX-RAW','原料',3,2),(32,'AUX-PACK','包材',3,2),
]
PHOTO_LEAF_IDS={11,12,21,22,23,24,25}
PRODUCT_IDS=[1,2,3,4,5,6,7,8,11,12,13,14,15]
PROFILES={
 1:(12,'small','unknown',21,D(50)),2:(12,'small','unknown',21,D(50)),3:(12,'small','unknown',21,D(50)),
 4:(24,'large','unknown',16,D(40)),5:(12,'small','unknown',21,D(50)),6:(12,'small','unknown',21,D(50)),
 7:(12,'small','unknown',20,D(1000)/D('19.2')),8:(29,'large','unknown',18,D(1)),
 11:(11,'large','unknown',16,D(40)),12:(21,'large','unknown',17,D(20)),
 13:(22,'bulk','unknown',None,D(0)),14:(23,'bulk','sea',None,D(0)),15:(25,'large','unknown',16,D(40)),
}

def material_definitions():
    rows=[]
    for mid,(code,name,feature,spec,price) in zip(PRODUCT_IDS,PRODUCTS):
        cat,pack,origin,_,_=PROFILES[mid]
        rows.append(dict(id=mid,code=code,name=name,spec=spec,category_id=cat,uom_id=1,kind='product',list_price_cents=price,lot_managed=True,salt_origin=origin,packaging=pack,product_feature=feature,classification_status='pending' if mid==8 else 'classified',source_note='新增品种与价格为模拟设计' if mid>=11 else '附件名称参考；来源未据品牌推定'))
    aux=[
      (9,'01010001','精制原盐（模拟原料）','散装',31,1,'raw',19000,'unknown','bulk'),
      (10,'040300013','编织袋-鲁晶-精制盐-400g-小包-平袋-高碘-袋装-20kg','20kg外袋',32,2,'packaging',35,'na','na'),
      (16,'DEMO-P025','通用25kg外袋（模拟）','25kg',32,2,'packaging',45,'na','na'),
      (17,'DEMO-P050','通用50kg外袋（模拟）','50kg',32,2,'packaging',65,'na','na'),
      (18,'DEMO-P1000','通用1000kg吨包（模拟）','1000kg',32,2,'packaging',2500,'na','na'),
      (19,'DEMO-RSEA','海盐粗盐（模拟原料）','散装',31,1,'raw',16000,'sea','bulk'),
      (20,'DEMO-P0192','通用19.2kg外箱（模拟）','19.2kg',32,3,'packaging',90,'na','na'),
      (21,'DEMO-P020','通用20kg外袋（模拟）','20kg',32,2,'packaging',35,'na','na'),
      (22,'DEMO-P0400','400g内包装袋（模拟）','400g',32,2,'packaging',3,'na','na'),
      (23,'DEMO-P0500','500g内包装袋（模拟）','500g',32,2,'packaging',4,'na','na'),
      (24,'DEMO-P0320','320g内包装袋（模拟）','320g',32,2,'packaging',3,'na','na'),
      (25,'DEMO-RKCL','氯化钾（模拟配方原料）','散装',31,1,'raw',600000,'unknown','bulk'),
      (26,'DEMO-RSEAWEED','海藻预混料（模拟配方原料）','散装',31,1,'raw',450000,'unknown','bulk'),
      (27,'DEMO-RFLAVOR','调味复配料（模拟配方原料）','散装',31,1,'raw',480000,'unknown','bulk'),
    ]
    for mid,code,name,spec,cat,unit,kind,price,origin,pack in aux:
        rows.append(dict(id=mid,code=code,name=name,spec=spec,category_id=cat,uom_id=unit,kind=kind,list_price_cents=price,lot_managed=True,salt_origin=origin,packaging=pack,product_feature='',classification_status='classified',source_note='模拟辅助物料，不进入产销盐品总计'))
    return sorted(rows,key=lambda r:r['id'])

def bom_components(mid):
    _,_,_,pack,packqty=PROFILES[mid]
    # Demonstration yield assumptions, not a food/pharmaceutical process specification.
    parts=[(19 if mid==14 else 9,D('1.00') if mid in (13,14) else D('1.03'))]
    if mid==5:parts=[(9,D('1.028')),(26,D('.002'))]
    if mid==6:parts=[(9,D('.824')),(27,D('.206'))]
    if mid==7:parts=[(9,D('.721')),(25,D('.309'))]
    if pack:parts.append((pack,packqty.quantize(D('.000001'))))
    if mid in (1,2,3):parts.append((22,D(2500)))
    if mid in (5,6):parts.append((23 if mid==5 else 22,D(2000) if mid==5 else D(2500)))
    if mid==7:parts.append((24,D(3125)))
    return parts
