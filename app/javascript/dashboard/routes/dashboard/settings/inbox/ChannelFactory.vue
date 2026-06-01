<script>
import { defineComponent, h } from 'vue';
import Facebook from './channels/Facebook.vue';
import Website from './channels/Website.vue';
import Twitter from './channels/Twitter.vue';
import Api from './channels/Api.vue';
import Email from './channels/Email.vue';
import Sms from './channels/Sms.vue';
import Whatsapp from './channels/Whatsapp.vue';
import WhatsappWeb from './channels/WhatsappWeb.vue';
import Line from './channels/Line.vue';
import Telegram from './channels/Telegram.vue';
import TelegramPersonal from './channels/TelegramPersonal.vue';
import LinkedinPersonal from './channels/LinkedinPersonal.vue';
import Weixin from './channels/Weixin.vue';
import VkCommunity from './channels/VkCommunity.vue';
import Instagram from './channels/Instagram.vue';
import Tiktok from './channels/Tiktok.vue';
import Voice from './channels/Voice.vue';

const channelViewList = {
  facebook: Facebook,
  website: Website,
  twitter: Twitter,
  api: Api,
  whatsapp_web: WhatsappWeb,
  email: Email,
  sms: Sms,
  whatsapp: Whatsapp,
  line: Line,
  telegram: Telegram,
  telegram_personal: TelegramPersonal,
  linkedin_personal: LinkedinPersonal,
  weixin: Weixin,
  vk_community: VkCommunity,
  instagram: Instagram,
  tiktok: Tiktok,
  voice: Voice,
};

export default defineComponent({
  name: 'NewChannelView',
  props: {
    channelName: {
      type: String,
      required: true,
    },
  },
  render() {
    const ChannelComponent = channelViewList[this.channelName];
    return ChannelComponent ? h(ChannelComponent) : null;
  },
});
</script>
